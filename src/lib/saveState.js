import {
	getAllFolds,
	getScrollPosition,
	getSelection,
} from "../codemirror/editorUtils";
import constants from "./constants";
import { addedFolder } from "./openFolder";
import appSettings from "./settings";

export default () => {
	if (!window.editorManager) return;

	const filesToSave = [];
	const folders = [];
	const { editor, files, activeFile } = editorManager;
	const { value: settings } = appSettings;

	files.forEach((file) => {
		if (file.type !== "editor") return;
		if (file.id === constants.DEFAULT_FILE_SESSION) return;
		if (file.SAFMode === "single") return;

		const fileJson = {
			id: file.id,
			uri: file.uri,
			type: file.type,
			filename: file.filename,
			isUnsaved: file.isUnsaved,
			readOnly: file.readOnly,
			SAFMode: file.SAFMode,
			deletedFile: file.deletedFile,
			cursorPos: getSelection(editor),
			scrollTop: getScrollPosition(editor).scrollTop,
			scrollLeft: getScrollPosition(editor).scrollLeft,
			editable: file.editable,
			encoding: file.encoding,
			render: activeFile.id === file.id,
			folds: getAllFolds(file.session),
		};

		if (settings.rememberFiles || fileJson.isUnsaved)
			filesToSave.push(fileJson);
	});

	if (settings.rememberFolders) {
		addedFolder.forEach((folder) => {
			const { url, saveState, title, listState, listFiles } = folder;
			folders.push({
				url,
				opts: {
					saveState,
					name: title,
					listState,
					listFiles,
				},
			});
		});
	}

	localStorage.files = JSON.stringify(filesToSave);
	localStorage.folders = JSON.stringify(folders);
};
