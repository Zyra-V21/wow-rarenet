// Run a Lua script with fengari: node tools/lua.js script.lua [args...]
const { lua, lauxlib, lualib, to_luastring } = require('fengari');
const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);
lua.lua_newtable(L);
process.argv.slice(3).forEach((a, i) => { lua.lua_pushstring(L, to_luastring(a)); lua.lua_rawseti(L, -2, i + 1); });
lua.lua_setglobal(L, to_luastring('arg'));
if (lauxlib.luaL_dofile(L, to_luastring(process.argv[2])) !== 0) {
  console.error(lua.lua_tojsstring(L, -1));
  process.exit(1);
}
