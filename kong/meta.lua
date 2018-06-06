local ee_meta = require "kong.enterprise_edition.meta"

local version = setmetatable({
  major = 0,
  minor = 13,
  patch = 1,
  --suffix = ""
}, {
  __tostring = function(t)
    return string.format("%d.%d.%d%s", t.major, t.minor, t.patch,
                         t.suffix or "")
  end
})

return {
  _NAME = "kong",
  _VERSION = tostring(ee_meta.versions.package) .. "-enterprise-edition",
  _VERSION_TABLE = ee_meta.versions.package,

  _CORE_VERSION = tostring(version),
  _CORE_VERSION_TABLE = version,

  -- third-party dependencies' required version, as they would be specified
  -- to lua-version's `set()` in the form {from, to}
  _DEPENDENCIES = {
    nginx = {"1.11.2.5", "1.13.6.2"},
  }
}
