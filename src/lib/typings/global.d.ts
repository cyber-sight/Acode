// Type definitions for globally available constants
// Project: https://github.com/deadlyjack/acode
// Definitions by: Gemini
//
/// <reference types="./types/attributes.d.ts" />

interface AceAjax {
  Editor: any;
  IEditSession: any;
  // Add other AceAjax types as needed
}

interface FtpOptions {
  connectionMode: "passive" | "active";
  securityType: "ftp" | "ftps";
  encoding: "utf8" | "binary";
}

type SuccessCallback = (res: any) => void;
type ErrorCallback = (err: any) => void;

interface Ftp {
  connect(
    host: string,
    port: number,
    username: string,
    password: string,
    options: FtpOptions,
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  listDirectory(
    id: string, // connection id
    path: string,
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  execCommand(
    id: string, // connection id
    command: string,
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
    ...args: string
  ): void;
  isConnected(
    id: string, // connection id
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  disconnect(
    id: string, // connection id
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  downloadFile(
    id: string, // connection id
    remotePath: string,
    localPath: string,
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  uploadFile(
    id: string, // connection id
    localPath: string,
    remotePath: string,
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  deleteFile(
    id: string, // connection id
    remotePath: string,
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  deleteDirectory(
    id: string, // connection id
    remotePath: string,
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  createDirectory(
    id: string, // connection id
    remotePath: string,
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  createFile(
    id: string, // connection id
    remotePath: string,
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  getStat(
    id: string, // connection id
    remotePath: string,
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  exists(
    id: string, // connection id
    remotePath: string,
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  changeDirectory(
    id: string, // connection id
    remotePath: string,
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  changeToParentDirectory(
    id: string, // connection id
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  getWorkingDirectory(
    id: string, // connection id
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  rename(
    id: string, // connection id
    oldPath: string,
    newPath: string,
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
  sendNoOp(
    id: string, // connection id
    onSuccess: SuccessCallback,
    onError: ErrorCallback,
  ): void;
}

interface Iap {
  getProducts(
    skuList: Array<string>,
    onSuccess: (skuList: Array<Object>) => void,
    onError: (err: String) => Error,
  ): void;
  setPurchaseUpdatedListener(
    onSuccess: (purchase: Object) => void,
    onError: (err: string) => void,
  ): void;
  startConnection(
    onSuccess: (responseCode: number) => void,
    onError: (err: string) => void,
  ): void;
  consume(
    purchaseToken: string,
    onSuccess: (responseCode: number) => void,
    onError: (err: string) => void,
  ): void;
  purchase(
    skuId: string,
    onSuccess: (responseCode: number) => void,
    onError: (err: string) => void,
  ): void;
  getPurchases(
    onSuccess: (purchaseList: Array<Object>) => void,
    onError: (err: string) => void,
  ): void;
  OK: 0;
  BILLING_UNAVAILABLE: 3;
  DEVELOPER_ERROR: 5;
  ERROR: 6;
  FEATURE_NOT_SUPPORTED: -2;
  ITEM_ALREADY_OWNED: 7;
  ITEM_UNAVAILABLE: 4;
  SERVICE_DISCONNECTED: -1;
  SERVICE_TIMEOUT: -3;
  SERVICE_UNAVAILABLE: 2;
  USER_CANCELED: 1;
  PURCHASE_STATE_PURCHASED: 1;
  PURCHASE_STATE_PENDING: 2;
  PURCHASE_STATE_UNKNOWN: 0;
}

interface Storage {
  /**
   * Name of the storage
   */
  name: string;
  /**
   * UUID of the storage
   */
  uuid: string;
}

interface DirListItem {
  name: string;
  mime: string;
  isDirectory: Boolean;
  isFile: Boolean;
  uri: string;
}

interface Stats {
  canRead: boolean;
  canWrite: boolean;
  exists: boolean; //indicates if file can be found on device storage
  isDirectory: boolean;
  isFile: boolean;
  isVirtual: boolean;
  lastModified: number;
  length: number;
  name: string;
  type: string;
  uri: string;
}

interface DocumentFile {
  canWrite: boolean;
  filename: string;
  length: number;
  type: string;
  uri: string;
}

interface SDcard {
  /**
   * Copy file/directory to given destination
   * @param src Source url
   * @param dest Destination url
   * @param onSuccess Callback function on success returns url of copied file/dir
   * @param onFail Callback function on error returns error object
   */
  copy(
    src: string,
    dest: string,
    onSuccess: (url: string) => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Creates new directory at given source url.
   * @param src Source url
   * @param dirName New directory name
   * @param onSuccess Callback function on success returns url of new directory
   * @param onFail Callback function on error returns error object
   */
  createDir(
    src: string,
    dirName: string,
    onSuccess: (url: string) => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Creates new file at given source url.
   * @param src Source url
   * @param fileName New file name
   * @param onSuccess Callback function on success returns url of new directory
   * @param onFail Callback function on error returns error object
   */
  createFile(
    src: string,
    fileName: string,
    onSuccess: (url: string) => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Deletes file/directory
   * @param src Source url of file/directory
   * @param onSuccess Callback function on success returns source url
   * @param onFail Callback function on error returns error object
   */
  delete(
    src: string,
    onSuccess: (url: string) => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Checks if given file/directory
   * @param src File/Directory url
   * @param onSuccess Callback function on success returns string "TRUE" or "FALSE"
   * @param onFail Callback function on error returns error object
   */
  exists(
    src: string,
    onSuccess: (exists: "TRUE" | "FALSE") => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Converts virtual URL to actual url
   * @param src Virtual address returned by other methods
   * @param onSuccess Callback function on success returns actual url
   * @param onFail Callback function on error returns error object
   */
  formatUri(
    src: string,
    onSuccess: (url: string) => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Gets actual url for relative path to src
   * e.g. getPath(src, "../path/to/file.txt") => actual url
   * @param src Directory url
   * @param path Relative file/directory path
   * @param onSuccess Callback function on success returns actual url
   * @param onFail Callback function on error returns error object
   */
  getPath(
    src: string,
    path: string,
    onSuccess: (url: string) => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Requests user for storage permission
   * @param uuid UUID returned from listStorages method
   * @param onSuccess Callback function on success returns url for the storage root
   * @param onFail Callback function on error returns error object
   */
  getStorageAccessPermission(
    uuid: string,
    onSuccess: (url: string) => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Lists all the storages
   * @param onSuccess Callback function on success returns list of storages
   * @param onFail Callback function on error returns error object
   */
  listStorages(
    onSuccess: (storages: Array<Storage>) => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Gets list of files/directory in the given directory
   * @param src Directory url
   * @param onSuccess Callback function on success returns list of files/directory
   * @param onFail Callback function on error returns error object
   */
  listDir(
    src: string,
    onSuccess: (list: Array<DirListItem>) => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Move file/directory to given destination
   * @param src Source url
   * @param dest Destination url
   * @param onSuccess Callback function on success returns url of moved file/dir
   * @param onFail Callback function on error returns error object
   */
  move(
    src: string,
    dest: string,
    onSuccess: (url: string) => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Opens file provider to select file
   * @param onSuccess Callback function on success returns url of selected file
   * @param onFail Callback function on error returns error object
   * @param mimeType MimeType of file to be selected
   */
  openDocumentFile(
    onSuccess: (url: DocumentFile) => void,
    onFail: (err: any) => void,
    mimeType: string,
  ): void;
  /**
   * Opens gallery to select image
   * @param onSuccess Callback function on success returns url of selected file
   * @param onFail Callback function on error returns error object
   * @param mimeType MimeType of file to be selected
   */
  getImage(
    onSuccess: (url: DocumentFile) => void,
    onFail: (err: any) => void,
    mimeType: string,
  ): void;
  /**
   * Renames the given file/directory to given new name
   * @param src Url of file/directory
   * @param newname New name
   * @param onSuccess Callback function on success returns url of renamed file
   * @param onFail Callback function on error returns error object
   */
  rename(
    src: string,
    newname: string,
    onSuccess: (url: string) => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Writes new content to the given file.
   * @param src file url
   * @param content new file content
   * @param onSuccess Callback function on success returns "OK"
   * @param onFail Callback function on error returns error object
   */
  write(
    src: string,
    content: string,
    onSuccess: (res: "OK") => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Writes new content to the given file.
   * @param src file url
   * @param content new file content
   * @param isBinary is data binary
   * @param onSuccess Callback function on success returns "OK"
   * @param onFail Callback function on error returns error object
   */
  write(
    src: string,
    content: string,
    isBinary: Boolean,
    onSuccess: (res: "OK") => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Gets stats of given file
   * @param src file/directory url
   * @param onSuccess Callback function on success returns file/directory stats
   * @param onFail Callback function on error returns error object
   */
  stats(
    src: string,
    onSuccess: (stats: Stats) => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Listens for file changes
   * @param src File url
   * @param listener Callback function on file change returns file stats
   */
  watchFile(
    src: string,
    listener: () => void,
  ): {
    unwatch: () => void;
  };
}

interface Server {
  stop(onSuccess: () => void, onError: (error: any) => void): void;
  send(
    id: string,
    data: any,
    onSuccess: () => void,
    onError: (error: any) => void,
  ): void;
  port: number;
}

interface Sftp {
  /**
   * Executes command on ssh-server
   * @param command
   * @param onSucess
   * @param onFail
   */
  exec(
    command: String,
    onSucess: (res: ExecResult) => void,
    onFail: (err: any) => void,
  ): void;
  /**
   * Connects to SFTP server
   * @param host Hostname of the server
   * @param port port numer
   * @param username Username
   * @param password Password or private key file to authenticate the server
   * @param onSuccess Callback function on success returns url of copied file/dir
   * @param onFail Callback function on error returns error object
   */
  connectUsingPassoword(
    host: String,
    port: Number,
    username: String,
    password: String,
    onSuccess: () => void,
    onFail: (err: any) => void,
  ): void;

  /**
   * Connects to SFTP server
   * @param host Hostname of the server
   * @param port port numer
   * @param username Username
   * @param keyFile Password or private key file to authenticate the server
   * @param passphrase Passphrase for keyfile
   * @param onSuccess Callback function on success returns url of copied file/dir
   * @param onFail Callback function on error returns error object
   */
  connectUsingKeyFile(
    host: String,
    port: Number,
    username: String,
    keyFile: String,
    passphrase: String,
    onSuccess: () => void,
    onFail: (err: any) => void,
  ): void;

  /**
   * Gets file from the server.
   * @param filename
   * @param localFilename copy/shadow of remote file.
   * @param onSuccess
   * @param onFail
   */
  getFile(
    filename: String,
    localFilename: String,
    onSuccess: (url: String) => void,
    onFail: (err: any) => void,
  ): void;

  /**
   * Uploaded the file to server
   * @param filename
   * @param localFilename copy/shadow of remote file.
   * @param onSuccess
   * @param onFail
   */
  putFile(
    filename: String,
    localFilename: String,
    onSuccess: (url: String) => void,
    onFail: (err: any) => void,
  ): void;

  /**
   * Closes the connection
   * @param onSuccess
   * @param onFail
   */
  close(onSuccess: () => void, onFail: (err: any) => void): void;

  /**
   * Gets wether server is connected or not.
   * @param onSuccess
   * @param onFail
   */
  isConnected(
    onSuccess: (connectionId: String) => void,
    onFail: (err: any) => void,
  ): void;
}

interface Info {
  versionName: string;
  packageName: string;
  versionCode: number;
}

interface AppInfo extends Info {
  label: string;
  firstInstallTime: number;
  lastUpdateTime: number;
}

interface ShortCut {
  id: string;
  label: string;
  description: string;
  icon: string;
  action: string;
  data: string;
}

interface Intent {
  action: string;
  data: string;
  type: string;
  package: string;
  extras: {
    [key: string]: any;
  };
}

type FileAction = "VIEW" | "EDIT" | "SEND" | "RUN";
type OnFail = (err: string) => void;
type OnSuccessBool = (res: boolean) => void;

interface System {
  /**
   * Get information about current webview
   */
  getWebviewInfo(onSuccess: (res: Info) => void, onFail: OnFail): void;
  /**
   * Checks if power saving mode is on
   * @param onSuccess
   * @param onFail
   */
  isPowerSaveMode(onSuccess: OnSuccessBool, onFail: OnFail): void;
  /**
   * File action using Apps content provider
   * @param fileUri File uri
   * @param filename file name
   * @param action file name
   * @param onFail
   */
  fileAction(
    fileUri: string,
    filename: string,
    action: FileAction,
    mimeType: string,
    onFail: OnFail,
  ): void;
  /**
   * File action using Apps content provider
   * @param fileUri File uri
   * @param filename file name
   * @param action file name
   */
  fileAction(
    fileUri: string,
    filename: string,
    action: FileAction,
    mimeType: string,
  ): void;
  /**
   * File action using Apps content provider
   * @param fileUri File uri
   * @param action file name
   * @param onFail
   */
  fileAction(
    fileUri: string,
    action: FileAction,
    mimeType: string,
    onFail: OnFail,
  ): void;
  /**
   * File action using Apps content provider
   * @param fileUri File uri
   * @param action file name
   */
  fileAction(fileUri: string, action: FileAction, mimeType: string): void;
  /**
   * File action using Apps content provider
   * @param fileUri File uri
   * @param action file name
   */
  fileAction(fileUri: string, action: FileAction, onFail: OnFail): void;
  /**
   * File action using Apps content provider
   * @param fileUri File uri
   * @param action file name
   */
  fileAction(fileUri: string, action: FileAction): void;
  /**
   * Gets app information
   * @param onSuccess
   * @param onFail
   */
  getAppInfo(onSuccess: (info: AppInfo) => void, onFail: OnFail): void;
  /**
   * Add shortcut to app context menu
   * @param shortCut
   * @param onSuccess
   * @param onFail
   */
  addShortcut(
    shortCut: ShortCut,
    onSuccess: OnSuccessBool,
    onFail: OnFail,
  ): void;
  /**
   * Removes shortcut
   * @param id
   * @param onSuccess
   * @param onFail
   */
  removeShortcut(id: string, onSuccess: OnSuccessBool, onFail: OnFail): void;
  /**
   * Pins a shortcut
   * @param id
   * @param onSuccess
   * @param onFail
   */
  pinShortcut(id: string, onSuccess: OnSuccessBool, onFail: OnFail): void;
  /**
   * Gets android version
   * @param onSuccess
   * @param onFail
   */
  getAndroidVersion(onSuccess: (res: Number) => void, onFail: OnFail): void;
  /**
   * Open settings which lets user change app settings to manage all files
   * @param onSuccess
   * @param onFail
   */
  manageAllFiles(onSuccess: OnSuccessBool, onFail: OnFail): void;
  /**
   * Opens settings to allow to grant the app permission manage all files on device
   * @param onSuccess
   * @param onFail
   */
  isExternalStorageManager(onSuccess: OnSuccessBool, onFail: OnFail): void;
  /**
   * Requests user to grant the provided permissions
   * @param permissions constant value of the permission required @see https://developer.android.com/reference/android/Manifest.permission
   * @param onSuccess
   * @param onFail
   */
  requestPermissions(
    permissions: string[],
    onSuccess: OnSuccessBool,
    onFail: OnFail,
  ): void;
  /**
   * Requests user to grant the provided permission
   * @param permission constant value of the permission required @see https://developer.android.com/reference/android/Manifest.permission
   * @param onSuccess
   * @param onFail
   */
  requestPermission(
    permission: string,
    onSuccess: OnSuccessBool,
    onFail: OnFail,
  ): void;
  /**
   * Checks whether the app has provided permission
   * @param permission constant value of the permission required @see https://developer.android.com/reference/android/Manifest.permission
   * @param onSuccess
   * @param onFail
   */
  hasPermission(
    permission: string,
    onSuccess: OnSuccessBool,
    onFail: OnFail,
  ): void;
  /**
   * Opens src in browser
   * @param src
   */
  openInBrowser(src: string): void;
  /**
   * Launches and app
   * @param app the package name of the app
   * @param className the full class name of the activity
   * @param data Data to pass to the app
   * @param onSuccess
   * @param onFail
   */
  launchApp(
    app: string,
    className: string,
    data: string,
    onSuccess: OnSuccessBool,
    onFail: OnFail,
  ): void;

  /**
   * Opens a link within the app
   * @param url Url to open
   * @param title Title of the page
   * @param showButtons Set to true to show buttons like console, open in browser, etc
   */
  inAppBrowser(url: string, title: string, showButtons: boolean): void;
  /**
   * Sets the color of status bar and navigation bar
   * @param systemBarColor Color of status bar and navigation bar
   * @param theme Theme as object
   * @param onSuccess Callback on success
   * @param onFail Callback on fail
   */
  setUiTheme(
    systemBarColor: string,
    theme: object,
    onSuccess: OnSuccessBool,
    onFail: OnFail,
  ): void;
  /**
   * Sets intent handler for the app
   * @param onSuccess
   * @param onFail
   */
  setIntentHandler(onSuccess: (intent: Intent) => void, onFail: OnFail): void;
  /**
   * Gets the launch intent
   * @param onSuccess
   * @param onFail
   */
  getCordovaIntent(onSuccess: (intent: Intent) => void, onFail: OnFail): void;
  getFilesDir(onSuccess: (res: string) => void, onFail: OnFail): void;
  fileExists(
    path: string,
    isDirectory: boolean,
    onSuccess: (res: 0 | 1) => void,
    onFail: OnFail,
  ): void;
  mkdirs(path: string, onSuccess: () => void, onFail: OnFail): void;
  writeText(
    path: string,
    content: string,
    onSuccess: () => void,
    onFail: OnFail,
  ): void;
  getArch(onSuccess: (arch: string) => void, onFail: OnFail): void;
}

interface ExecResult {
  code: Number;
  result: String;
}

interface Executor {
  start(
    command: string,
    onData: (type: "stdout" | "stderr" | "exit", data: string) => void,
    alpine?: boolean,
  ): Promise<string>;
  write(uuid: string, input: string): Promise<string>;
  stop(uuid: string): Promise<string>;
  isRunning(uuid: string): Promise<boolean>;
  execute(command: string, alpine?: boolean): Promise<string>;
  loadLibrary(path: string): Promise<string>;
}

interface Terminal {
  startAxs(
    installing?: boolean,
    logger?: Function,
    err_logger?: Function,
  ): Promise<boolean | void>;
  stopAxs(): Promise<void>;
  isAxsRunning(): Promise<boolean>;
  install(logger?: Function, err_logger?: Function): Promise<boolean>;
  isInstalled(): Promise<boolean>;
  isSupported(): Promise<boolean>;
  backup(): Promise<string>;
  restore(): Promise<string>;
  uninstall(): Promise<string>;
}

interface Strings {
  [key: string]: string;
}

interface BuildInfo {
  version: string;
  versionCode: number;
  packageName: string;
}

interface Cordova {
  exec(
    success: Function,
    error: Function,
    service: string,
    action: string,
    args: any[],
  ): void;
  file: {
    applicationDirectory: string;
    externalDataDirectory: string;
    dataDirectory: string;
    externalCacheDirectory: string;
    cacheDirectory: string;
  };
  plugin: {
    http: {
      sendRequest(
        url: string,
        options: any,
        success: Function,
        error: Function,
      ): void;
      downloadFile(
        url: string,
        options: any,
        headers: any,
        filePath: string,
        success: Function,
        error: Function,
      ): void;
    };
  };
}

interface Device {
  platform: string;
  version: string;
  uuid: string;
  model: string;
  manufacturer: string;
  isVirtual: boolean;
  serial: string;
}

interface Ace {
  edit(el: HTMLElement | string): any; // Ace.Editor
  createEditSession(text: string, mode?: string): any; // Ace.EditSession
  require(module: string): any;
  config: {
    set(key: string, value: any): void;
  };
}

type HTMLTagNames = keyof HTMLElementTagNameMap & string;

interface HTMLElement {}

type StyleList = {
  [key in keyof CSSStyleDeclaration]?: CSSStyleDeclaration[key];
};

type Dataset = {
  [key: string]: string;
};

type EnterKeyHint =
  | "enter"
  | "done"
  | "go"
  | "next"
  | "previous"
  | "search"
  | "send";

interface Tag {
  <K extends HTMLTagNames>(
    tagName: K,
    options?: HTMLElementAttributes & object,
  ): HTMLElementTagNameMap[K];
  <K extends HTMLTagNames>(
    tagName: K,
    innerHTML: string,
  ): HTMLElementTagNameMap[K];
  (tagName: string, options?: HTMLElementAttributes & object): HTMLElement;
  (tagName: string, innerHTML: string): HTMLElement;
  /**
   * Returns the first element that is a descendant of node that matches selectors.
   */
  get<K extends keyof HTMLElementTagNameMap>(
    selectors: K,
  ): HTMLElementTagNameMap[K] | null;
  get<K extends keyof SVGElementTagNameMap>(
    selectors: K,
  ): SVGElementTagNameMap[K] | null;
  get<K extends keyof MathMLElementTagNameMap>(
    selectors: K,
  ): MathMLElementTagNameMap[K] | null;
  get<E extends Element = Element>(selectors: string): E | null;
  /**
   * Returns all element descendants of node that match selectors.
   */
  getAll<K extends keyof HTMLElementTagNameMap>(
    selectors: K,
  ): NodeListOf<HTMLElementTagNameMap[K]>;
  getAll<K extends keyof SVGElementTagNameMap>(
    selectors: K,
  ): NodeListOf<SVGElementTagNameMap[K]>;
  getAll<K extends keyof MathMLElementTagNameMap>(
    selectors: K,
  ): NodeListOf<MathMLElementTagNameMap[K]>;
  getAll<E extends Element = Element>(selectors: string): NodeListOf<E>;
  text(text: string): Text;
}

declare global {
  const app: HTMLElement;
  const root: HTMLElement;
  const addedFolder: Folder[];
  const editorManager: EditorManagerInstance;
  const toast: (message: string, duration?: number) => void;
  const ASSETS_DIRECTORY: string;
  const DATA_STORAGE: string;
  const CACHE_STORAGE: string;
  const PLUGIN_DIR: string;
  const KEYBINDING_FILE: string;
  let IS_FREE_VERSION: boolean;
  const log: (
    level: "error" | "warn" | "info" | "debug",
    message: string | Error,
  ) => void;
  const ANDROID_SDK_INT: number;
  const DOES_SUPPORT_THEME: boolean;
  const acode: Acode;
  const actionStack: AcodeActionStack; // Deprecated, use acode.actionStack

  // Cordova Plugins
  const ftp: Ftp;
  const iap: Iap;
  const sdcard: SDcard;
  const CreateServer: (
    port: number,
    onSuccess: (msg: any) => void,
    onError: (err: any) => void,
  ) => Server;
  const sftp: Sftp;
  const system: System;
  const Executor: Executor;
  const Terminal: Terminal;

  // Other global variables
  const strings: Strings;
  const BuildInfo: BuildInfo;
  const cordova: Cordova;
  const device: Device;
  const ace: Ace;
  const emmet: any; // Placeholder, define more specifically if needed
  const tag: Tag;
}
