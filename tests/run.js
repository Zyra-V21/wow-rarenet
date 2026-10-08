// Runs tests/test_rarenet.lua in a Lua VM (fengari, Lua 5.3; the client runs 5.1).
const { lua, lauxlib, lualib, to_luastring } = require('fengari');
const path = require('path');
const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);
lua.lua_pushstring(L, to_luastring(path.join(__dirname, '..') + '/'));
lua.lua_setglobal(L, to_luastring('ROOT'));
if (lauxlib.luaL_dofile(L, to_luastring(path.join(__dirname, 'test_rarenet.lua'))) !== 0) {
  console.error(lua.lua_tojsstring(L, -1));
  process.exit(1);
}
