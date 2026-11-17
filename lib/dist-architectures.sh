# Architectures per distribution for jenkins-debian-glue.
#
# Sourced by the jdg-* scripts. DIST_ARCHITECTURES (e.g. in
# /etc/jenkins/debian_glue) says which architectures a distribution can build
# at all, one rule per line, "<patterns> : <architectures>". The first line
# with a matching shell pattern wins:
#
#   DIST_ARCHITECTURES='
#   raspbian-*                         : armhf
#   ubuntu-*                           : amd64 arm64 armhf
#   debian-buster debian-bullseye      : amd64 i386
#   debian-*                           : amd64 i386 armhf arm64 armel
#   '
#
# Used by jdg-generate-reprepro-codename (architectures of a new codename) and
# jdg-set-combination-filter (which matrix cells may exist).

# jdg_dist_architectures <distribution>: print the architectures of a
# distribution; prints nothing if DIST_ARCHITECTURES is unset or no rule
# matches.
jdg_dist_architectures() {
  local line pats archs pat
  [ -n "${DIST_ARCHITECTURES:-}" ] || return 0
  while IFS= read -r line ; do
    case "${line#"${line%%[![:space:]]*}"}" in
      \#*) continue ;;   # comment
      *:*) ;;
      *) continue ;;     # no rule
    esac
    pats="${line%%:*}"
    archs="${line#*:}"
    set -f
    for pat in $pats ; do
      # shellcheck disable=SC2254
      case "${1:-}" in
        $pat)
          set +f
          # shellcheck disable=SC2086
          echo $archs
          return 0
          ;;
      esac
    done
    set +f
  done <<< "${DIST_ARCHITECTURES}"
  return 0
}
