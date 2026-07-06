import alert from "dialogs/alert";
import openFile from "lib/openFile";
import openFolder, { addedFolder } from "lib/openFolder";
import helpers from "utils/helpers";
import Url from "utils/Url";

function getOpenErrorMessage(prefix, err) {
	const error =
		err?.message || err?.localizedDescription || err?.error || err?.code || err;
	const message = helpers.errorMessage(error);
	return message ? `${prefix}. ${message}` : prefix;
}

/**
 * @typedef {"file"|"folder"|"both"} BrowseMode
 * @typedef {{type: 'file' | 'folder', url: String, name: String}} SelectedFile
 */

/**
 *
 * @param {BrowseMode} [mode='file'] Specify file browser mode, value can be 'file', 'folder' or 'both'
 * @param {string} info A small message to show what's file browser is opened for
 * @param {boolean} doesOpenLast Should file browser open lastly visited directory?
 * @param {Array<{name: String, url: String}>} defaultDir Default directory to open.
 * @returns {Promise<SelectedFile>}
 */
function FileBrowser(mode, info, doesOpenLast, ...args) {
	return new Promise((resolve, reject) => {
		import(/* webpackChunkName: "fileBrowser" */ "./fileBrowser").then(
			(res) => {
				const FileBrowser = res.default;
				FileBrowser(mode, info, doesOpenLast, ...args)
					.then(resolve)
					.catch(reject);
			},
		);
	});
}

FileBrowser.openFile = (res) => {
	const { url, name, mode } = res;
	const createOption = {
		uri: url,
		name,
		render: true,
	};

	if (mode) {
		createOption.mode = mode;
	}

	openFile(url, createOption);
};

FileBrowser.openFileError = (err) => {
	const ERROR = strings.error.toUpperCase();
	if (err?.code === 0) return;
	alert(ERROR, getOpenErrorMessage(strings["unable to open file"], err));
};

FileBrowser.openFolder = async (res) => {
	const { url, name } = res;
	const protocol = Url.getProtocol(url);

	if (protocol === "ftp:") {
		openFolder(url, {
			name: name,
			saveState: false,
		});
	} else {
		openFolder(url, {
			name: name,
		});
	}

	const folder = addedFolder.find((folder) => folder.url === url);
	folder?.$node?.$title?.click();
};

FileBrowser.openFolderError = (err) => {
	const ERROR = strings.error.toUpperCase();
	if (err?.code === 0) return;
	alert(ERROR, getOpenErrorMessage(strings["unable to open folder"], err));
};

FileBrowser.open = (res) => {
	if (res.type === "folder") {
		FileBrowser.openFolder(res);
		return;
	}

	FileBrowser.openFile(res);
};

FileBrowser.openError = (err) => {
	FileBrowser.openFileError(err);
};

export default FileBrowser;
