const exec = require("cordova/exec");

function invoke(action, args) {
  return new Promise((resolve, reject) => exec(resolve, reject, "RootfsManager", action, args || []));
}

module.exports = {
  list: () => invoke("list"),
  importArchive: (sourceUrl, name) => invoke("importArchive", [sourceUrl, name]),
  importDirectory: (sourceUrl, name) => invoke("importDirectory", [sourceUrl, name]),
  activate: (id) => invoke("activate", [id]),
  rename: (id, name) => invoke("rename", [id, name]),
  delete: (id) => invoke("delete", [id]),
  getActivePublicHome: () => invoke("getActivePublicHome"),
  reconcileFs: () => invoke("reconcileFs"),
};
