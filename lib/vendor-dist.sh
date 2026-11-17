# Vendor-qualified distributions for jenkins-debian-glue.
#
# Sourced by the jdg-* scripts. Enabled with VENDOR_DISTRIBUTIONS=true (e.g. in
# /etc/jenkins/debian_glue). The distribution axis is then always
# "<vendor>-<codename>" (debian-trixie, raspbian-trixie, ubuntu-noble) and each
# vendor gets its own reprepro archive below DEFAULT_REPOSITORY, so inside an
# archive suites use the plain codenames, exactly like the vendors themselves.
#
# Why: Raspbian reuses Debian's codenames *and* the architecture name armhf
# (but means ARMv6), so both cannot share one archive. Qualifying every
# distribution with its vendor removes all special cases.
#
# Settings (all optional):
#   JDG_VENDORS                  vendors to recognise (default: debian raspbian ubuntu)
#   MAIN_ARCHITECTURE_<vendor>   primary architecture of a vendor, i.e. the one
#                                that builds Arch:all packages
#                                (default: armhf for raspbian, amd64 otherwise)

JDG_VENDORS="${JDG_VENDORS:-debian raspbian ubuntu}"

# jdg_vendor_enabled: true if vendor-qualified distributions are switched on.
jdg_vendor_enabled() {
  [ "${VENDOR_DISTRIBUTIONS:-}" = "true" ]
}

# jdg_vendor_split <distribution>
# Sets DIST_VENDOR and DIST_CODENAME; returns 1 if the name is not qualified
# with one of JDG_VENDORS.
jdg_vendor_split() {
  local dist="${1:-}" vendor
  DIST_VENDOR=""
  DIST_CODENAME=""
  for vendor in ${JDG_VENDORS} ; do
    case "${dist}" in
      "${vendor}"-?*)
        DIST_VENDOR="${vendor}"
        DIST_CODENAME="${dist#"${vendor}"-}"
        return 0
        ;;
    esac
  done
  return 1
}

# jdg_vendor_main_arch <vendor>: print the primary architecture of a vendor.
jdg_vendor_main_arch() {
  local var="MAIN_ARCHITECTURE_${1:-}"
  if [ -n "${!var:-}" ] ; then
    printf '%s\n' "${!var}"
    return 0
  fi
  case "${1:-}" in
    raspbian) printf 'armhf\n' ;;
    *)        printf 'amd64\n' ;;
  esac
}

# jdg_vendor_codename <name>: strip the vendor prefix from a vendor-qualified
# name (e.g. a TRUNK_RELEASE or DIST equal to the distribution); other names
# are printed unchanged.
jdg_vendor_codename() {
  local DIST_VENDOR DIST_CODENAME
  if jdg_vendor_split "${1:-}" ; then
    printf '%s\n' "${DIST_CODENAME}"
  else
    printf '%s\n' "${1:-}"
  fi
}

# jdg_vendor_repository <default repository> <distribution>: the reprepro
# archive of a distribution, <default repository>/<vendor> for a
# vendor-qualified one, else <default repository>.
jdg_vendor_repository() {
  local DIST_VENDOR DIST_CODENAME
  if jdg_vendor_enabled && jdg_vendor_split "${2:-}" ; then
    printf '%s/%s\n' "${1%/}" "${DIST_VENDOR}"
  else
    printf '%s\n' "${1}"
  fi
}

# jdg_vendor_mirror <vendor> <architecture>: default mirror of a vendor
# (MIRROR_<vendor> overrides it).
jdg_vendor_mirror() {
  local var="MIRROR_${1:-}"
  if [ -n "${!var:-}" ] ; then
    printf '%s\n' "${!var}"
    return 0
  fi
  case "${1:-}" in
    ubuntu)
      case "${2:-}" in
        amd64|i386) printf 'http://archive.ubuntu.com/ubuntu\n' ;;
        *)          printf 'http://ports.ubuntu.com/ubuntu-ports\n' ;;
      esac
      ;;
    raspbian) printf 'http://raspbian.raspberrypi.com/raspbian\n' ;;
    *)        printf 'http://deb.debian.org/debian\n' ;;
  esac
}

# jdg_vendor_components <vendor>: archive components for debootstrap.
jdg_vendor_components() {
  case "${1:-}" in
    ubuntu)   printf 'main,universe,restricted,multiverse\n' ;;
    raspbian) printf 'main,contrib,non-free,rpi\n' ;;
    *)        printf 'main,contrib,non-free\n' ;;
  esac
}
