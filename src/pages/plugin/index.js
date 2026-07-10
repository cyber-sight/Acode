function plugin({ id, install }, onInstall, onUninstall) {
	import(/* webpackChunkName: "plugin" */ "./plugin").then((res) => {
		const Plugin = res.default;
		Plugin(id, onInstall, onUninstall, install);
	});
}

export default plugin;
