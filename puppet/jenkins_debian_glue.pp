# architecture of the matrix jobs: fact jdg_debian_arch, else the system's
$jdg_arch = $facts['jdg_debian_arch'] ? {
  undef   => $facts['os']['architecture'],
  default => $facts['jdg_debian_arch'],
}

if defined('$ec2_public_ipv4') {
  $jenkins_server = $ec2_public_ipv4
} elsif defined('$ipaddress') {
  $jenkins_server = $ipaddress
} else {
  $jenkins_server = 'YOUR_JENKINS_SERVER'
}

class jenkins::repos {

  package { 'gnupg':
    ensure => present,
  }

  package { 'wget':
    ensure => present,
  }

  # apt-key is gone since Debian trixie: keyring file + signed-by
  file { '/etc/apt/keyrings':
    ensure => directory,
    mode   => '0755',
  }

  exec { 'jenkins-keyring':
    command => '/usr/bin/wget -O /etc/apt/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key',
    creates => '/etc/apt/keyrings/jenkins-keyring.asc',
    require => [
      File['/etc/apt/keyrings'],
      Package['wget'],
    ],
  }

  file { '/etc/apt/sources.list.d/jenkins.list':
    ensure  => present,
    content => "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/\n",
    require => Exec['jenkins-keyring'],
  }

  exec { 'refresh-apt-jenkins':
    require     => [
      File['/etc/apt/sources.list.d/jenkins.list'],
      Exec['jenkins-keyring'],
    ],
    subscribe   => File['/etc/apt/sources.list.d/jenkins.list'],
    refreshonly => true,
    command     => '/usr/bin/apt-get update',
  }
}


class jenkins::software {

  package { 'default-jre-headless':
    ensure => present,
  }

  package { 'jenkins':
    ensure  => present,
    require => [
      File['/etc/apt/sources.list.d/jenkins.list'],
      File['/etc/sudoers.d/jenkins'],
      Exec['refresh-apt-jenkins'],
      Package['default-jre-headless'],
    ]
  }

  package { [ 'jenkins-debian-glue',
            'jenkins-debian-glue-buildenv' ]:
    ensure  => present,
  }

  service { 'jenkins':
    ensure  => running,
    require => [
      Package['jenkins'],
    ]
  }

  package { 'sudo':
    ensure => present,
  }

  file { '/etc/sudoers.d/jenkins':
    mode    => '0440',
    content => '## Deployed via jenkins_debian_glue.pp

# Make sure DEB_* options reach cowbuilder, like e.g.:
#  export DEB_BUILD_OPTIONS="parallel=8" /usr/bin/jdg-build-and-provide-package
Defaults  env_keep+="DEB_* DIST ARCH ADT MIRRORSITE"

# for *-binaries job
jenkins ALL=NOPASSWD: /usr/sbin/cowbuilder, /usr/sbin/chroot
# for *-piuparts job
jenkins ALL=NOPASSWD: /usr/sbin/piuparts, /usr/sbin/debootstrap, /usr/bin/jdg-piuparts-wrapper
',
    require => Package['sudo'],
  }
}


class jenkins::reprepro {
  file { '/srv/repository':
    ensure  => directory,
    mode    => '0755',
    owner   => 'jenkins',
    require => Package['jenkins'],
  }
}


class jenkins::config {
  file { '/var/lib/jenkins/.gitconfig':
    ensure  => present,
    mode    => '0644',
    owner   => 'jenkins',
    content =>'[user]
        email = jenkins@example.org
        name = Jenkins User
',
    require => Package['jenkins'],
  }

  # API user for jdg-set-combination-filter (the source jobs set the
  # combination filter of the -binaries/-repos jobs through the API): with
  # Jenkins' own user database create the user jdg-api once and store
  # "jdg-api:<token>" in $JENKINS_HOME/jdg-api-token (mode 0600)
  file { '/var/lib/jenkins/init.groovy.d':
    ensure  => directory,
    mode    => '0755',
    owner   => 'jenkins',
    require => Package['jenkins'],
  }

  # plugins the jenkins-debian-glue jobs need: installed (with their
  # dependencies) from the update center when Jenkins starts, followed by one
  # restart so that the jobs using them load
  file { '/var/lib/jenkins/init.groovy.d/jdg-plugins.groovy':
    ensure  => present,
    mode    => '0644',
    owner   => 'jenkins',
    require => File['/var/lib/jenkins/init.groovy.d'],
    notify  => Service['jenkins'],
    content => @(GROOVY),
      // Deployed via jenkins_debian_glue.pp
      import jenkins.model.Jenkins

      def wanted = ["git", "matrix-project", "copyartifact", "ws-cleanup", "junit", "tap"]

      def jenkins = Jenkins.get()
      def pm = jenkins.pluginManager
      def missing = wanted.findAll { pm.getPlugin(it) == null }
      if (missing.isEmpty()) {
        return
      }

      Thread.start {
        // a new thread runs as anonymous: installing plugins needs SYSTEM
        def acl = hudson.security.ACL.as2(hudson.security.ACL.SYSTEM2)
        try {
          jenkins.updateCenter.updateAllSites()
          // PluginManager.install resolves the dependencies (like the setup wizard)
          def ok = true
          pm.install(missing, false).each { future ->
            try {
              def job = future.get()
              if (job.hasProperty("status") && job.status instanceof hudson.model.UpdateCenter.DownloadJob.Failure) {
                ok = false
                println("jdg-plugins: " + job + ": " + job.status.problem)
              }
            } catch (Exception e) {
              ok = false
              println("jdg-plugins: " + e)
            }
          }
          println("jdg-plugins: installed " + missing.join(" ") + (ok ? ", restarting Jenkins" : " with errors"))
          if (ok) {
            jenkins.safeRestart()
          }
        } finally {
          acl.close()
        }
      }
      | GROOVY
  }

  file { '/var/lib/jenkins/init.groovy.d/jdg-api-user.groovy':
    ensure  => present,
    mode    => '0644',
    owner   => 'jenkins',
    require => File['/var/lib/jenkins/init.groovy.d'],
    notify  => Service['jenkins'],
    content => @(GROOVY),
      // Deployed via jenkins_debian_glue.pp
      import java.nio.file.Files
      import java.nio.file.attribute.PosixFilePermissions
      import hudson.model.Item
      import hudson.model.User
      import hudson.security.HudsonPrivateSecurityRealm
      import jenkins.model.Jenkins
      import jenkins.security.ApiTokenProperty

      def jenkins = Jenkins.get()
      def tokenFile = new File(jenkins.rootDir, "jdg-api-token")
      def name = "jdg-api"

      if (tokenFile.exists()) {
        return
      }
      def realm = jenkins.securityRealm
      if (!(realm instanceof HudsonPrivateSecurityRealm)) {
        println("jdg-api: no Jenkins user database; for jdg-set-combination-filter put "
                + "user:apitoken of a user with Job/Read and Job/Configure into " + tokenFile)
        return
      }

      def user = User.getById(name, false)
      if (user == null) {
        user = realm.createAccount(name, UUID.randomUUID().toString() + UUID.randomUUID().toString())
        user.setFullName("jenkins-debian-glue API")
      }
      def prop = user.getProperty(ApiTokenProperty.class)
      if (prop == null) {
        prop = new ApiTokenProperty()
        user.addProperty(prop)
      }
      def token = prop.tokenStore.generateNewToken("jdg-set-combination-filter")
      user.save()

      // matrix-based security: allow reading and configuring jobs
      def strategy = jenkins.authorizationStrategy
      if (strategy.getClass().name.endsWith("MatrixAuthorizationStrategy")) {
        try {
          [Jenkins.READ, Item.READ, Item.CONFIGURE].each { strategy.add(it, name) }
          jenkins.save()
        } catch (Exception e) {
          println("jdg-api: grant " + name + " Overall/Read, Job/Read and Job/Configure: " + e)
        }
      }

      Files.createFile(tokenFile.toPath(),
                       PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")))
      tokenFile.text = name + ":" + token.plainValue + "\n"
      println("jdg-api: API token written to " + tokenFile)
      | GROOVY
  }

  file { '/var/lib/jenkins/jobs':
    ensure  => directory,
    mode    => '0755',
    owner   => 'jenkins',
    require => Package['jenkins'],
  }

  file { '/var/lib/jenkins/jobs/jenkins-debian-glue-source':
    ensure  => directory,
    mode    => '0755',
    owner   => 'jenkins',
    require => Package['jenkins'],
  }

  file { '/var/lib/jenkins/jobs/jenkins-debian-glue-source/config.xml':
    ensure  => present,
    mode    => '0644',
    owner   => 'jenkins',
    require => File['/var/lib/jenkins/jobs/jenkins-debian-glue-source'],
    notify  => Service['jenkins'],
    content => "<?xml version='1.0' encoding='UTF-8'?>
<project>
  <actions/>
  <description>Build Debian source package of jenkins-debian-glue</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <scm class='hudson.plugins.git.GitSCM'>
    <configVersion>2</configVersion>
    <userRemoteConfigs>
      <hudson.plugins.git.UserRemoteConfig>
        <name></name>
        <refspec></refspec>
        <url>https://github.com/mika/jenkins-debian-glue.git</url>
      </hudson.plugins.git.UserRemoteConfig>
    </userRemoteConfigs>
    <branches>
      <hudson.plugins.git.BranchSpec>
        <name>master</name>
      </hudson.plugins.git.BranchSpec>
    </branches>
    <disableSubmodules>false</disableSubmodules>
    <recursiveSubmodules>false</recursiveSubmodules>
    <doGenerateSubmoduleConfigurations>false</doGenerateSubmoduleConfigurations>
    <authorOrCommitter>false</authorOrCommitter>
    <clean>false</clean>
    <wipeOutWorkspace>false</wipeOutWorkspace>
    <pruneBranches>false</pruneBranches>
    <remotePoll>false</remotePoll>
    <ignoreNotifyCommit>false</ignoreNotifyCommit>
    <buildChooser class='hudson.plugins.git.util.DefaultBuildChooser'/>
    <gitTool>Default</gitTool>
    <submoduleCfg class='list'/>
    <relativeTargetDir>source</relativeTargetDir>
    <reference></reference>
    <excludedRegions></excludedRegions>
    <excludedUsers></excludedUsers>
    <gitConfigName></gitConfigName>
    <gitConfigEmail></gitConfigEmail>
    <skipTag>false</skipTag>
    <includedRegions></includedRegions>
    <scmName></scmName>
  </scm>
  <canRoam>true</canRoam>
  <disabled>false</disabled>
  <blockBuildWhenDownstreamBuilding>false</blockBuildWhenDownstreamBuilding>
  <blockBuildWhenUpstreamBuilding>false</blockBuildWhenUpstreamBuilding>
  <triggers class='vector'/>
  <concurrentBuild>false</concurrentBuild>
  <builders>
    <hudson.tasks.Shell>
      <command>rm -f ./* || true</command>
    </hudson.tasks.Shell>
    <hudson.tasks.Shell>
      <command># when using git:
/usr/bin/jdg-generate-git-snapshot

# when using subversion:
# /usr/bin/jdg-generate-svn-snapshot</command>
    </hudson.tasks.Shell>
    <hudson.tasks.Shell>
      <command># keep the combination filter of the -binaries/-repos matrix jobs in
# line with debian/control and DIST_ARCHITECTURES (/etc/jenkins/debian_glue)
/usr/bin/jdg-set-combination-filter --apply --package jenkins-debian-glue \\
    --control source/debian/control || echo &quot;*** WARNING: combination filter not updated ***&quot;</command>
    </hudson.tasks.Shell>
    <hudson.tasks.Shell>
      <command>mkdir -p report
/usr/bin/jdg-lintian-junit-report *.dsc &gt; report/lintian.xml</command>
    </hudson.tasks.Shell>
  </builders>
  <publishers>
    <hudson.tasks.ArtifactArchiver>
      <artifacts>*.gz,*.bz2,*.xz,*.deb,*.dsc,*.git,*.changes,*.buildinfo,lintian.txt</artifacts>
      <latestOnly>false</latestOnly>
    </hudson.tasks.ArtifactArchiver>
    <hudson.tasks.Fingerprinter>
      <targets></targets>
      <recordBuildArtifacts>true</recordBuildArtifacts>
    </hudson.tasks.Fingerprinter>
    <hudson.tasks.BuildTrigger>
      <childProjects>jenkins-debian-glue-binaries</childProjects>
      <threshold>
        <name>SUCCESS</name>
        <ordinal>0</ordinal>
        <color>BLUE</color>
      </threshold>
    </hudson.tasks.BuildTrigger>
    <hudson.tasks.junit.JUnitResultArchiver>
      <testResults>**/lintian.xml</testResults>
      <keepLongStdio>false</keepLongStdio>
      <testDataPublishers/>
    </hudson.tasks.junit.JUnitResultArchiver>
  </publishers>
  <buildWrappers/>
</project>
"
  }

  file { '/var/lib/jenkins/jobs/jenkins-debian-glue-binaries':
    ensure  => directory,
    mode    => '0755',
    owner   => 'jenkins',
    require => Package['jenkins'],
  }

  file { '/var/lib/jenkins/jobs/jenkins-debian-glue-binaries/config.xml':
    ensure  => present,
    mode    => '0644',
    owner   => 'jenkins',
    require => File['/var/lib/jenkins/jobs/jenkins-debian-glue-binaries'],
    notify  => Service['jenkins'],
    content => "<?xml version='1.0' encoding='UTF-8'?>
<matrix-project>
  <actions/>
  <description>&lt;p&gt;Build Debian binary packages of jenkins-debian-glue&lt;/p&gt;&#xd;
&#xd;
&lt;h2&gt;Usage instructions how to remotely access and use the repository&lt;/h2&gt;&#xd;
&#xd;
&lt;p&gt;Install apache webserver:&lt;/p&gt;&#xd;
&#xd;
&lt;pre&gt;&#xd;
  sudo apt-get install apache2&#xd;
  sudo ln -s /srv/repository /var/www/debian&#xd;
&lt;/pre&gt;&#xd;
&#xd;
&lt;p&gt;Then access to this repository is available using the following sources.list entry:&lt;/p&gt;&#xd;
&#xd;
&lt;pre&gt;&#xd;
  deb     http://${jenkins_server}/debian/ jenkins-debian-glue main&#xd;
  deb-src http://${jenkins_server}/debian/ jenkins-debian-glue main&#xd;
&lt;/pre&gt;</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <scm class='hudson.scm.NullSCM'/>
  <canRoam>true</canRoam>
  <disabled>false</disabled>
  <blockBuildWhenDownstreamBuilding>false</blockBuildWhenDownstreamBuilding>
  <blockBuildWhenUpstreamBuilding>false</blockBuildWhenUpstreamBuilding>
  <triggers class='vector'/>
  <concurrentBuild>false</concurrentBuild>
  <axes>
    <hudson.matrix.TextAxis>
      <name>architecture</name>
      <values>
        <string>${jdg_arch}</string>
      </values>
    </hudson.matrix.TextAxis>
  </axes>
  <builders>
    <hudson.plugins.copyartifact.CopyArtifact>
      <projectName>jenkins-debian-glue-source</projectName>
      <filter>*</filter>
      <target></target>
      <selector class='hudson.plugins.copyartifact.TriggeredBuildSelector'>
        <fallbackToLastSuccessful>true</fallbackToLastSuccessful>
      </selector>
    </hudson.plugins.copyartifact.CopyArtifact>
    <hudson.tasks.Shell>
      <command>export POST_BUILD_HOOK=/usr/bin/jdg-debc
/usr/bin/jdg-build-and-provide-package</command>
    </hudson.tasks.Shell>
    <hudson.tasks.Shell>
      <command>echo &quot;Listing packages inside the jenkins-debian-glue repository:&quot;
/usr/bin/jdg-repository-checker --list-repos jenkins-debian-glue</command>
    </hudson.tasks.Shell>
    <hudson.tasks.Shell>
      <command>mkdir -p report
/usr/bin/jdg-lintian-junit-report *.dsc &gt; report/lintian.xml</command>
    </hudson.tasks.Shell>
  </builders>
  <publishers>
    <hudson.tasks.ArtifactArchiver>
      <artifacts>*.gz,*.bz2,*.xz,*.deb,*.dsc,*.git,*.changes,*.buildinfo,lintian.txt</artifacts>
      <latestOnly>false</latestOnly>
    </hudson.tasks.ArtifactArchiver>
    <hudson.tasks.Fingerprinter>
      <targets></targets>
      <recordBuildArtifacts>true</recordBuildArtifacts>
    </hudson.tasks.Fingerprinter>
    <hudson.tasks.junit.JUnitResultArchiver>
      <testResults>**/lintian.xml</testResults>
      <keepLongStdio>false</keepLongStdio>
      <testDataPublishers/>
    </hudson.tasks.junit.JUnitResultArchiver>
    <hudson.tasks.BuildTrigger>
      <childProjects>jenkins-debian-glue-piuparts</childProjects>
      <threshold>
        <name>SUCCESS</name>
        <ordinal>0</ordinal>
        <color>BLUE</color>
      </threshold>
    </hudson.tasks.BuildTrigger>
  </publishers>
  <buildWrappers>
    <hudson.plugins.ws__cleanup.PreBuildCleanup>
      <deleteDirs>false</deleteDirs>
    </hudson.plugins.ws__cleanup.PreBuildCleanup>
  </buildWrappers>
  <executionStrategy class='hudson.matrix.DefaultMatrixExecutionStrategyImpl'>
    <runSequentially>true</runSequentially>
  </executionStrategy>
</matrix-project>
"
  }

  file { '/var/lib/jenkins/jobs/jenkins-debian-glue-piuparts/':
    ensure  => directory,
    mode    => '0755',
    owner   => 'jenkins',
    require => Package['jenkins'],
  }

  file { '/var/lib/jenkins/jobs/jenkins-debian-glue-piuparts/config.xml':
    ensure  => present,
    mode    => '0644',
    owner   => 'jenkins',
    require => File['/var/lib/jenkins/jobs/jenkins-debian-glue-piuparts/'],
    notify  => Service['jenkins'],
    content => "<?xml version='1.0' encoding='UTF-8'?>
<project>
  <actions/>
  <description>Installation and upgrade tests for jenkins-debian-glue Debian packages</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.StringParameterDefinition>
          <name>architecture</name>
          <description></description>
          <defaultValue>${jdg_arch}</defaultValue>
        </hudson.model.StringParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
  </properties>
  <scm class='hudson.scm.NullSCM'/>
  <canRoam>true</canRoam>
  <disabled>false</disabled>
  <blockBuildWhenDownstreamBuilding>false</blockBuildWhenDownstreamBuilding>
  <blockBuildWhenUpstreamBuilding>false</blockBuildWhenUpstreamBuilding>
  <triggers class='vector'/>
  <concurrentBuild>false</concurrentBuild>
  <builders>
    <hudson.plugins.copyartifact.CopyArtifact>
      <project>jenkins-debian-glue-binaries/architecture=\$architecture</project>
      <filter>*.deb</filter>
      <target>artifacts/</target>
      <selector class='hudson.plugins.copyartifact.TriggeredBuildSelector'>
        <fallbackToLastSuccessful>true</fallbackToLastSuccessful>
      </selector>
      <flatten>true</flatten>
    </hudson.plugins.copyartifact.CopyArtifact>
    <hudson.tasks.Shell>
      <command># sadly piuparts always returns with exit code 1 :((
sudo jdg-piuparts-wrapper \${PWD}/artifacts/*.deb || true</command>
    </hudson.tasks.Shell>
    <hudson.tasks.Shell>
      <command>jdg-tap-piuparts piuparts.txt &gt; piuparts.tap</command>
    </hudson.tasks.Shell>
  </builders>
  <publishers>
    <org.tap4j.plugin.TapPublisher>
      <testResults>piuparts.tap</testResults>
      <failIfNoResults>false</failIfNoResults>
      <failedTestsMarkBuildAsFailure>false</failedTestsMarkBuildAsFailure>
      <outputTapToConsole>false</outputTapToConsole>
      <enableSubtests>true</enableSubtests>
      <discardOldReports>false</discardOldReports>
      <todoIsFailure>false</todoIsFailure>
    </org.tap4j.plugin.TapPublisher>
    <hudson.tasks.ArtifactArchiver>
      <artifacts>piuparts.*</artifacts>
      <latestOnly>false</latestOnly>
      <allowEmptyArchive>false</allowEmptyArchive>
    </hudson.tasks.ArtifactArchiver>
  </publishers>
  <buildWrappers>
    <hudson.plugins.ws__cleanup.PreBuildCleanup>
      <deleteDirs>false</deleteDirs>
    </hudson.plugins.ws__cleanup.PreBuildCleanup>
  </buildWrappers>
</project>
"
  }

}

## software
include jenkins::repos
include jenkins::software
include jenkins::config
include jenkins::reprepro
