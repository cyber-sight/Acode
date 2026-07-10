function invoke(action, args = []) {
	return new Promise((resolve, reject) => {
		if (typeof cordova === "undefined" || cordova.platformId !== "ios") {
			reject(new Error("Root filesystem management is available on iOS only."));
			return;
		}
		cordova.exec(resolve, reject, "RootfsManager", action, args);
	});
}

const rootfsManager = {
	list() {
		return invoke("list");
	},
	importArchive(sourceUrl, name) {
		return invoke("importArchive", [sourceUrl, name]);
	},
	importDirectory(sourceUrl, name) {
		return invoke("importDirectory", [sourceUrl, name]);
	},
	activate(id) {
		return invoke("activate", [id]);
	},
	rename(id, name) {
		return invoke("rename", [id, name]);
	},
	delete(id) {
		return invoke("delete", [id]);
	},
	getActivePublicHome() {
		return invoke("getActivePublicHome");
	},
};

export default rootfsManager;
