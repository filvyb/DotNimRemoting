switch("path", "$projectDir/../src")
#switch("mm", "refc")
when findExe("mold").len > 0 and defined(linux):
  switch("passL", "-fuse-ld=mold")