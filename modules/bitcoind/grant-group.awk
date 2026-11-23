# Reads the output of `getfacl -n -E` and prints the input for `setfacl --restore`
# that gives the owning group at least the rights in `access`, like "r-x".
# With `defaults`, it also gives the group these rights in each dir's default
# ACL, and creates a default ACL for a dir that has none.
#
# The rights go to the owning group of each entry, so a record whose owning
# group isn't `gid` is left alone with a message, and the exit status is 1.
#
# Every other entry keeps its effective rights. A named user or group has the
# rights that its entry and the mask have in common. So where the mask gains a
# right, the named entries lose it.
#
# Prints only the records that change. They have no owner and group lines, so
# setfacl doesn't chown. They keep the flags line, because setfacl clears the
# setuid, setgid and sticky bits that a record doesn't list. A file `./name`
# becomes `name`, so that `setfacl -P` needs no lookup of a dir part.

BEGIN { RS = ""; FS = "\n" }

# The rights in a or b
function union(a, b,   i, r) {
  for (i = 1; i <= 3; i++)
    r = r (substr(b, i, 1) != "-" ? substr(b, i, 1) : substr(a, i, 1))
  return r
}

# The rights in a that aren't in b
function without(a, b,   i, r) {
  for (i = 1; i <= 3; i++)
    r = r (substr(b, i, 1) != "-" ? "-" : substr(a, i, 1))
  return r
}

function fail(message) {
  print "grant-group.awk: " message > "/dev/stderr"
  exit 1
}

function addEntry(line) {
  if (line !~ /^(default:)?(user|group|mask|other):[^:]*:[r-][w-][x-]$/)
    fail("unexpected getfacl output: " line)
  n++
  tag[n] = substr(line, 1, length(line) - 4)
  perms[n] = substr(line, length(line) - 2)
  old[n] = perms[n]
  entry[tag[n]] = n
}

# Gives the owning group the rights in `want` in the ACL whose tags start with `type`
function grant(type, want,   mask, gained, i) {
  if ((type "mask:") in entry) {
    mask = entry[type "mask:"]
    gained = without(want, perms[mask])
    for (i = 1; i <= n; i++)
      if (tag[i] ~ ("^" type "(user|group):."))
        perms[i] = without(perms[i], gained)
    perms[mask] = union(perms[mask], want)
  }
  perms[entry[type "group:"]] = union(perms[entry[type "group:"]], want)
}

{
  n = 0
  header = ""
  group = ""
  delete entry
  for (f = 1; f <= NF; f++) {
    field = $f
    sub(/^# file: \.\//, "# file: ", field)
    if (field ~ /^# (file|flags): /)
      header = header field "\n"
    else if (field ~ /^# group: /)
      group = substr(field, 10)
    else if (field !~ /^# owner: /)
      addEntry(field)
  }
  if (group != gid) {
    print "grant-group.awk: " substr($1, 9) " belongs to group " group ", not " gid \
      ", so it's left alone" > "/dev/stderr"
    skipped = 1
    next
  }
  if (!("group:" in entry))
    fail("no owning group entry in record: " $1)
  grant("", access)
  if (defaults != "") {
    if (!("default:group:" in entry)) {
      addEntry("default:user::rwx")
      addEntry("default:group::---")
      addEntry("default:other::---")
      old[n] = ""
    }
    grant("default:", defaults)
  }

  if (changed())
    printRecord()
}

END { if (skipped) exit 1 }

function changed(   i) {
  for (i = 1; i <= n; i++)
    if (perms[i] != old[i])
      return 1
  return 0
}

function printRecord(   i) {
  printf "%s", header
  for (i = 1; i <= n; i++)
    print tag[i] ":" perms[i]
  print ""
}
