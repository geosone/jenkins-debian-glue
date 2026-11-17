#!/bin/bash

start_seconds=$(sed -e 's/^\([0-9]*\).*/\1/' < /proc/uptime)
[ -n "$start_seconds" ] && SECONDS="$[$(sed -e 's/^\([0-9]*\).*/\1/' < /proc/uptime)-$start_seconds]" || SECONDS="unknown"

if [ -r /var/lib/jenkins/config.xml ] ; then
  echo "NOTE: Configuration file /var/lib/jenkins/config.xml exists already."

  if [ "$1" == "--force" ] ; then
    echo "Continuing execution as requested via --force."
  else
    echo "Exiting to avoid possible data loss. To force execution, run '$0 --force'" >&2
    exit 1
  fi
fi

# workaround for puppet's facter, which looks at `uname -m` (reporting e.g. aarch64)
# while `dpkg --print-architecture` reports arm64
export FACTER_JDG_DEBIAN_ARCH="$(dpkg --print-architecture)"

if [ -z "${FACTER_JDG_DEBIAN_ARCH:-}" ] ; then
  echo "Error reporting Debian architecture (via 'dpkg --print-architecture')" >&2
  exit 1
fi

if ! [ -r jenkins_debian_glue.pp ] ; then
  wget https://raw.github.com/mika/jenkins-debian-glue/master/puppet/jenkins_debian_glue.pp
fi

if ! [ -r jenkins_debian_glue.pp ] ; then
  echo "Error: can not find jenkins_debian_glue.pp." >&2
  echo "Make sure to fetch e.g. https://raw.github.com/mika/jenkins-debian-glue/master/puppet/jenkins_debian_glue.pp" >&2
  exit 1
fi

# OpenVox, the community fork of Puppet: from the distribution where it is
# packaged (Debian >= forky), else from https://apt.voxpupuli.org/ (the
# openvoxN-release package configures that repository and its key)
install_openvox() {
  local id version release major
  apt-get update
  if apt-cache show openvox-agent >/dev/null 2>&1 ; then
    apt-get -y install openvox-agent
    return
  fi

  . /etc/os-release
  id="${ID}"
  case "${id}" in
    debian) version="${VERSION_ID%%.*}" ;;
    ubuntu) version="${VERSION_ID}" ;;
    *) echo "Error: no OpenVox packages for ${ID}, install openvox-agent manually." >&2 ; return 1 ;;
  esac

  apt-get -y install wget ca-certificates || return 1
  for major in 9 8 ; do
    release="openvox${major}-release-${id}${version}.deb"
    if wget --quiet -O "/tmp/${release}" "https://apt.voxpupuli.org/${release}" ; then
      dpkg -i "/tmp/${release}" || return 1
      rm -f "/tmp/${release}"
      apt-get update
      apt-get -y install openvox-agent
      return
    fi
  done
  echo "Error: no OpenVox release package for ${id} ${version} on apt.voxpupuli.org." >&2
  return 1
}

# openvox-agent from apt.voxpupuli.org installs to /opt/puppetlabs/bin
export PATH="${PATH}:/opt/puppetlabs/bin"

if ! type puppet &>/dev/null ; then
  install_openvox || exit 1
fi

# Amazon EC2 returns the internal IP by default, so ask about the public one
IP=$(facter ec2_public_ipv4 2>/dev/null) # curl http://169.254.169.254/latest/meta-data/public-ipv4
# 'facter ec2_public_ipv4' returns nothing on Debian's AMI :(
if [ -z "$IP" ] ; then
  IP=$(wget --quiet --tries=3 --timeout=3 -O - http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)
fi

# try Google Compute Engine
if [ -z "$IP" ] ; then
  IP=$(wget --quiet --tries=3 --timeout=3 -O - "http://metadata/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" --header "X-Google-Metadata-Request: True" 2>/dev/null)
fi

# neither using EC2 nor GCE? use a fallback then
if [ -z "$IP" ] ; then
  IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')
fi

if [[ "$(hostname -f 2>/dev/null)" == "" ]] ; then
  echo "Error: please make sure you have a valid FQDN configured in /etc/hosts" >&2
  echo "NOTE:  Something like adding the following snippet to /etc/hosts might help:

$IP $(hostname).example.org $(hostname)
"
  exit 1
fi

package_check() {
  local package="$1"
  [ "$(dpkg-query -f "\${db:Status-Status} \${db:Status-Eflag}" -W "$package" 2>/dev/null)" = 'installed ok' ]
}

package_installed() {
  local packages="$*"

  for package in $packages ; do
    if ! package_check "$package" ; then
      return 1
    fi
  done
}

if puppet apply jenkins_debian_glue.pp ; then
  if ! package_installed jenkins jenkins-debian-glue; then
    echo "While puppet reported a successful run, jenkins and/or jenkins-debian-glue aren't successfully installed. :(" >&2
    echo "Please re-execute this script and if the problem persists please report this at" >&2
    echo "https://github.com/mika/jenkins-debian-glue/issues" >&2
    exit 1
  fi

  [ -n "$start_seconds" ] && SECONDS="$[$(sed -e 's/^\([0-9]*\).*/\1/' < /proc/uptime)-$start_seconds]" || SECONDS="unknown"
  echo "jenkins-debian-glue deployment finished after ${SECONDS} seconds."
else
  echo "Fatal error during puppet run. :(" >&2
  exit 1
fi

echo "
Jenkins installs the plugins the jenkins-debian-glue jobs need (git,
matrix-project, copyartifact, ws-cleanup, junit, tap) on its first start and
restarts once afterwards, which takes a few minutes.

Then unlock Jenkins with the setup wizard at http://${IP}:8080 (the initial
admin password is in /var/lib/jenkins/secrets/initialAdminPassword).

If building the jenkins-debian-glue* jobs should fail, check the plugins at
http://${IP}:8080/manage/pluginManager/installed and run this again:

  sudo $(command -v puppet) apply ./jenkins_debian_glue.pp

Enjoy your Jenkins setup."
