#switch("mm", "refc")
when findExe("mold").len > 0 and defined(linux):
  switch("passL", "-fuse-ld=mold")

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
