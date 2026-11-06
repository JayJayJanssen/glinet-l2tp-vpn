-- /usr/share/gl-validator.d/l2tp.lua
-- The panel's generic argument check only allows letters, digits and a few symbols in
-- strings, which would reject most passwords. set_config validates its own arguments
-- strictly (see the module), so the generic check is skipped for it only.
return {
    set_config = true
}
