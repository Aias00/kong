local ee_meta = require "kong.enterprise_edition.meta"

local version = setmetatable({
  major = 2,
  minor = 2,
  patch = 0,
  suffix = "rc.1"
}, {
  -- our Makefile during certain releases adjusts this line. Any changes to
  -- the format need to be reflected in both places
  __tostring = function(t)
    return string.format("%d.%d.%d%s", t.major, t.minor, t.patch,
                         t.suffix or "")
  end
})

return {
  _NAME = "kong",
  _VERSION = tostring(ee_meta.versions.package) .. "-enterprise-edition",
  _VERSION_TABLE = version,
  _SERVER_TOKENS = "kong/" .. tostring(ee_meta.versions.package) .. "-enterprise-edition",

  _CORE_VERSION = tostring(version),
  _CORE_VERSION_TABLE = version,

  -- third-party dependencies' required version, as they would be specified
  -- to lua-version's `set()` in the form {from, to}
  _DEPENDENCIES = {
    nginx = { "1.15.8.1", "1.17.8.2" },
  }
}
