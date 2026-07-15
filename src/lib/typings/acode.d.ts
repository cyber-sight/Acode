// Type definitions for Acode
// Project: https://github.com/deadlyjack/acode
// Definitions by: Gemini

/**
 * Interface for modules that can be registered with Acode.
 * This provides autocompletion for `acode.require(module)`.
 */
interface AcodeModules {
  "url": AcodeUrl;
  "page": Page;
  "color": (defaultColor?: string, onhide?: () => void) => Promise<string>;
  "fonts": AcodeFonts;
  "toast": (message: string, duration?: number) => void;
  "alert": (title: string, message: string, onhide?: () => void) => void;
  "select": (
    title: string,
    items: string[] | SelectItem[] | Array<[string, string, string?, boolean?, string?, boolean?]>,
    options?: SelectOptions | boolean
  ) => Promise<string>;
  "loader": AcodeLoader;
  "dialogbox": (
    titleText: string,
    html: string,
    hideButtonText?: string,
    cancelButtonText?: string
  ) => BoxPromiseLike;
  "prompt": (
    message: string,
    defaultValue?: string,
    type?: PromptInputType,
    options?: PromptOptions
  ) => Promise<string | number | null>;
  "intent": AcodeIntent;
  "filelist": AcodeFiles;
  "fs": AcodeFsOperation;
  "confirm": (titleText: string, message: string, isHTML?: boolean) => Promise<boolean>;
  "helpers": AcodeHelpers;
  "palette": AcodePalette;
  "projects": AcodeProjects;
  "tutorial": (id: string, message: string | HTMLElement | ((hide: () => void) => HTMLElement)) => void;
  "acemodes": AcodeAceModes;
  "themes": AcodeThemes;
  "settings": Settings;
  "sidebutton": typeof SideButton;
  "editorfile": EditorFile;
  "inputhints": typeof inputhints;
  "openfolder": AcodeOpenFolder;
  "colorpicker": (color: string) => Promise<string>;
  "actionstack": AcodeActionStack;
  "multiprompt": typeof multiPrompt;
  "addedfolder": Folder[];
  "contextmenu": typeof Contextmenu;
  "filebrowser": AcodeFileBrowser;
  "fsoperation": AcodeFsOperation;
  "keyboard": AcodeKeyboardHandler;
  "windowresize": AcodeWindowResize;
  "encodings": AcodeEncodings;
  "themebuilder": typeof ThemeBuilder;
  "selectionmenu": AcodeSelectionMenu;
  "sidebarapps": AcodeSidebarApps;
  "terminal": AcodeTerminal;
  "createkeyboardevent": typeof KeyboardEvent;
  "tointernalurl": (url: string) => Promise<string>;
}

interface AcodeUrl {
  basename(url: string): string | null;
  areSame(...urls: string[]): boolean;
  extname(url: string): string | null;
  join(...pathnames: string[]): string | null;
  safe(url: string): string;
  pathname(url: string): string | null;
  dirname(url: string): string | null;
  parse(url: string): { url: string; query: string };
  formate(urlObj: {
    protocol: "ftp:" | "sftp:" | "http:" | "https:";
    hostname: string | number;
    path?: string;
    username?: string;
    password?: string;
    port?: string | number;
    query?: object;
  }): string;
  getProtocol(url: string): "ftp:" | "sftp:" | "http:" | "https:" | "";
  hidePassword(url: string): string;
  decodeUrl(url: string): {
    username?: string;
    password?: string;
    hostname?: string;
    pathname?: string;
    port?: number;
    query: any; // This query object can contain keyFile and passPhrase, so keeping it as any for now.
  };
  trimSlash(url: string): string;
  PROTOCOL_PATTERN: RegExp;
}

declare class Page {
  constructor(title: string, opts?: {
    lead?: string;
    sub?: string;
    url?: string;
    history?: boolean;
    default?: boolean;
    unmountOnHide?: boolean;
    onHide?: () => void;
    onShow?: () => void;
    onMount?: () => void;
    onUnmount?: () => void;
  });
  /**
   * Shows the page
   * @param load Whether to load the page or not
   */
  show(load?: boolean): void;
  /**
   * Hides the page
   */
  hide(): void;
  /**
   * Destroys the page
   */
  destroy(): void;
  /**
   * Sets the title of the page
   * @param title
   */
  setTitle(title: string): void;
  /**
   * Sets the lead of the page
   * @param lead
   */
  setLead(lead: string): void;
  /**
   * Sets the sub of the page
   * @param sub
   */
  setSub(sub: string): void;
  /**
   * Sets the URL of the page
   * @param url
   */
  setUrl(url: string): void;
  /**
   * Adds a button to the page
   * @param id
   * @param icon
   * @param onclick
   * @param pos
   */
  addButton(id: string, icon: string, onclick: () => void, pos?: 'left' | 'right'): void;
  /**
   * Removes a button from the page
   * @param id
   */
  removeButton(id: string): void;
  /**
   * Gets a button from the page
   * @param id
   */
  getButton(id: string): HTMLElement | null;
  /**
   * Sets the onhide function
   * @param onhide
   */
  onhide(onhide: () => void): void;
  /**
   * Sets the onshow function
   * @param onshow
   */
  onshow(onshow: () => void): void;
  /**
   * Sets the onmount function
   * @param onmount
   */
  onmount(onmount: () => void): void;
  /**
   * Sets the onunmount function
   * @param onunmount
   */
  onunmount(onunmount: () => void): void;
  /**
   * Gets the page element
   */
  get $page(): HTMLElement;
  /**
   * Gets the header element
   */
  get $header(): HTMLElement;
  /**
   * Gets the body element
   */
  get $body(): HTMLElement;
  /**
   * Gets the title element
   */
  get $title(): HTMLElement;
  /**
   * Gets the lead element
   */
  get $lead(): HTMLElement;
  /**
   * Gets the sub element
   */
  get $sub(): HTMLElement;
  /**
   * Gets the URL
   */
  get url(): string;
  /**
   * Gets the ID
   */
  get id(): string;
  /**
   * Gets the title
   */
  get title(): string;
  /**
   * Gets the lead
   */
  get lead(): string;
  /**
   * Gets the sub
   */
  get sub(): string;
  /**
   * Gets the history status
   */
  get history(): boolean;
  /**
   * Gets the default status
   */
  get default(): boolean;
  /**
   * Gets the unmountOnHide status
   */
  get unmountOnHide(): boolean;
}

interface AcodeFonts {
  add(name: string, css: string): void;
  get(name: string): string | undefined;
  getNames(): string[];
  remove(name: string): boolean;
  has(name: string): boolean;
  setFont(name: string): Promise<void>;
  loadFont(name: string): Promise<string>;
}

// New interfaces for select, loader, and prompt
interface SelectOptions {
  hideOnSelect?: boolean;
  textTransform?: boolean;
  default?: string;
  onCancel?: () => void;
  onHide?: () => void;
}

interface SelectItem {
  value?: string;
  text?: string;
  icon?: string;
  disabled?: boolean;
  letters?: string;
  checkbox?: boolean;
  tailElement?: HTMLElement;
  ontailclick?: (event: Event) => void;
}

interface LoaderInstance {
  setTitle(title: string): void;
  setMessage(message: string): void;
  hide(): void;
  show(): void;
  destroy(): void;
}

interface LoaderOptions {
  timeout?: number;
  oncancel?: () => void;
}

interface AcodeLoader {
  create(titleText: string, message?: string, options?: LoaderOptions): LoaderInstance;
  destroy(): void;
  hide(): void;
  show(): void;
  showTitleLoader(immortal?: boolean): void;
  removeTitleLoader(immortal?: boolean): void;
}

interface BoxPromiseLike {
  hide(): void;
  wait(time: number): BoxPromiseLike;
  onclick(callback: (this: HTMLElement, ev: Event) => void): BoxPromiseLike;
  onhide(callback: () => void): BoxPromiseLike;
  then(callback: (children: HTMLCollection) => void): BoxPromiseLike;
  ok(callback: () => void): BoxPromiseLike;
  cancel(callback: () => void): BoxPromiseLike;
}

type PromptInputType = "textarea" | "text" | "number" | "tel" | "search" | "email" | "url" | "filename";

interface PromptOptions {
  match?: RegExp;
  required?: boolean;
  placeholder?: string;
  test?: (value: any) => boolean;
}

interface Intent {
  action: string;
  fileUri?: string;
  data?: string;
}

declare class IntentEvent {
  module: string;
  action: string;
  value: string;
  readonly defaultPrevented: boolean;
  readonly propagationStopped: boolean;
  constructor(module: string, action: string, value: string);
  preventDefault(): void;
  stopPropagation(): void;
}

interface AcodeIntent {
  addHandler(handler: (intent: IntentEvent) => void): void;
  removeHandler(handler: (intent: IntentEvent) => void): void;
}

interface FileListEventMap {
  "add-file": (tree: Tree) => void;
  "remove-file": (item: string | Tree) => void;
  "add-folder": (tree: Tree) => void;
  "remove-folder": (tree: Tree) => void;
  "refresh": (filesTree: { [url: string]: Tree }) => void;
}

declare class Tree {
  constructor(name: string, url: string, isDirectory: boolean);
  static create(url: string, name?: string, isDirectory?: boolean): Promise<Tree>;
  static createRoot(url: string, name: string): Promise<Tree>;
  name: string;
  url: string;
  path: string;
  children: Tree[] | null;
  parent: Tree | null;
  isConnected: boolean;
  root: Tree;
  update(url: string, name?: string): void;
  toJSON(): {
    name: string;
    url: string;
    path: string;
    parent: string | undefined;
    isDirectory: boolean;
  };
  static fromJSON(json: {
    name: string;
    url: string;
    path: string;
    parent: string;
    isDirectory: boolean;
  }): Tree;
}

interface AcodeFiles {
  (dir?: string | ((item: Tree) => any)): Tree[] | Tree | undefined;
  on<K extends keyof FileListEventMap>(event: K, callback: FileListEventMap[K]): void;
  off<K extends keyof FileListEventMap>(event: K, callback: FileListEventMap[K]): void;
  append(parent: string, child: string): Promise<void>;
  remove(item: string): void;
  refresh(): Promise<void>;
  rename(oldUrl: string, newUrl: string): void;
  addRoot(folder: { url: string; name: string }): Promise<void>;
}

type FileContent = string | Blob | ArrayBuffer;

interface Stat {
  name: string;
  url: string;
  uri: string; // deprecated
  isFile: boolean;
  isDirectory: boolean;
  isLink: boolean;
  size: number;
  modifiedDate: number;
  canRead: boolean;
  canWrite: boolean;
}

interface File {
  name: string;
  url: string;
  isFile: boolean;
  isDirectory: boolean;
  isLink: boolean;
}

interface FileSystem {
  lsDir(): Promise<File[]>;
  delete(): Promise<void>;
  exists(): Promise<boolean>;
  stat(): Promise<Stat>;
  readFile(encoding?: string, progress?: (event: ProgressEvent) => void): Promise<FileContent>;
  writeFile(data: FileContent, encoding?: string, progress?: (event: ProgressEvent) => void): Promise<void>;
  createFile(name: string, data: FileContent): Promise<string>;
  createDirectory(name: string): Promise<string>;
  copyTo(dest: string): Promise<string>;
  moveTo(dest: string): Promise<string>;
  renameTo(newname: string): Promise<string>;
}

interface AcodeFsOperation {
  (...url: string[]): FileSystem;
  extend(test: (url: string) => boolean, fs: (url: string) => FileSystem): void;
  remove(test: (url: string) => boolean): void;
}

interface AcodeHelpers {
  decodeText(arrayBuffer: ArrayBuffer, encoding?: string): string | object | null; // Deprecated
  getIconForFile(filename: string): string;
  sortDir(list: any[], fileBrowser: any, mode?: 'both' | 'file' | 'folder'): any[];
  errorMessage(err: Error | string, ...args: string[]): string;
  error(err: Error | string, ...args: string[]): Promise<void>;
  uuid(): string;
  parseJSON(jsonString: string): object | null;
  isDir(type: 'dir' | 'directory' | 'folder'): boolean;
  isFile(type: 'file' | 'link'): boolean;
  getVirtualPath(url: string): string;
  updateUriOfAllActiveFiles(oldUrl: string, newUrl: string): void;
  showAd(): void;
  hideAd(force?: boolean): void;
  toInternalUri(uri: string): Promise<string>;
  promisify<T>(func: Function, ...args: any[]): Promise<T>;
  checkAPIStatus(): Promise<boolean>;
  fixFilename(name: string): string;
  debounce(func: Function, wait: number): Function;
  defineDeprecatedProperty(obj: object, name: string, getter: Function, setter: Function): void;
  parseHTML(html: string): HTMLElement | HTMLElement[];
  createFileStructure(uri: string, pathString: string, isFile?: boolean): Promise<{ uri: string; type: 'file' | 'folder' }>;
  formatDownloadCount(downloadCount: number): string;
  isBinary(file: string): boolean;
}

interface HintModification {
  value: string;
  cursor: {
    start: number;
    end: number;
  };
}

interface AcodePalette {
  (getList: (hints: HintModification) => string[] | Promise<string[]>, onsSelectCb: (value: string) => void, placeholder: string, onremove?: () => void): void;
}

interface ProjectItem {
  name: string;
  icon: string;
}

interface ProjectFiles {
  (): Promise<{ [filename: string]: string }>;
}

interface AcodeProjects {
  list(): ProjectItem[];
  get(project: string): { files: ProjectFiles; icon: string } | undefined;
  set(project: string, files: ProjectFiles, iconSrc: string): void;
  delete(project: string): void;
}

interface Theme {
  id: string;
  name: string;
  type: string;
  version: string;
  primaryColor: string;
}

declare class ThemeBuilder {
  version: string;
  name: string;
  type: string;
  darkenedPrimaryColor: string;
  autoDarkened: boolean;
  preferredEditorTheme: string | null;
  preferredFont: string | null;

  constructor(name?: string, type?: 'dark' | 'light', version?: 'free' | 'paid');

  get id(): string;
  get popupBorderRadius(): string;
  set popupBorderRadius(value: string);
  get activeColor(): string;
  set activeColor(value: string);
  get activeIconColor(): string;
  set activeIconColor(value: string);
  get borderColor(): string;
  set borderColor(value: string);
  get boxShadowColor(): string;
  set boxShadowColor(value: string);
  get buttonActiveColor(): string;
  set buttonActiveColor(value: string);
  get buttonBackgroundColor(): string;
  set buttonBackgroundColor(value: string);
  get buttonTextColor(): string;
  set buttonTextColor(value: string);
  get errorTextColor(): string;
  set errorTextColor(value: string);
  get primaryColor(): string;
  set primaryColor(value: string);
  get primaryTextColor(): string;
  set primaryTextColor(value: string);
  get secondaryColor(): string;
  set secondaryColor(value: string);
  get secondaryTextColor(): string;
  set secondaryTextColor(value: string);
  get linkTextColor(): string;
  set linkTextColor(value: string);
  get scrollbarColor(): string;
  set scrollbarColor(value: string);
  get popupBorderColor(): string;
  set popupBorderColor(value: string);
  get popupIconColor(): string;
  set popupIconColor(value: string);
  get popupBackgroundColor(): string;
  set popupBackgroundColor(value: string);
  get popupTextColor(): string;
  set popupTextColor(value: string);
  get popupActiveColor(): string;
  set popupActiveColor(value: string);
  get dangerColor(): string;
  set dangerColor(value: string);
  get fileTabWidth(): string;
  set fileTabWidth(value: string);
  get activeTextColor(): string;
  set activeTextColor(value: string);

  get css(): string;
  toJSON(colorType?: 'rgba' | 'hex' | 'none'): { [key: string]: string };
  toString(): string;
  darkenPrimaryColor(): void;

  static fromCSS(name: string, css: string): ThemeBuilder;
  static fromJSON(theme: any): ThemeBuilder; // 'any' because the input can be a raw object
}

interface FileBrowserSettings {
  showHiddenFiles: boolean;
  sortByName: boolean;
}

interface SearchSettings {
  caseSensitive: boolean;
  regExp: boolean;
  wholeWord: boolean;
}

interface FormatterSettings {
  [mode: string]: string; // formatter id
}

interface PluginDisabledSettings {
  [pluginId: string]: boolean;
}

interface AppSettingsValue {
  animation: string;
  appTheme: string;
  autosave: number;
  fileBrowser: FileBrowserSettings;
  formatter: FormatterSettings;
  maxFileSize: number;
  serverPort: number;
  previewPort: number;
  showConsoleToggler: boolean;
  previewMode: string;
  disableCache: boolean;
  useCurrentFileForPreview: boolean;
  host: string;
  search: SearchSettings;
  lang: string;
  fontSize: string;
  editorTheme: string;
  textWrap: boolean;
  softTab: boolean;
  tabSize: number;
  retryRemoteFsAfterFail: boolean;
  linenumbers: boolean;
  formatOnSave: boolean;
  fadeFoldWidgets: boolean;
  autoCorrect: boolean;
  openFileListPos: string;
  quickTools: number;
  quickToolsTriggerMode: string;
  editorFont: string;
  vibrateOnTap: boolean;
  fullscreen: boolean;
  floatingButton: boolean;
  liveAutoCompletion: boolean;
  showPrintMargin: boolean;
  printMargin: number;
  scrollbarSize: number;
  showSpaces: boolean;
  confirmOnExit: boolean;
  lineHeight: number;
  leftMargin: number;
  checkFiles: boolean;
  desktopMode: boolean;
  console: string;
  keyboardMode: string;
  rememberFiles: boolean;
  rememberFolders: boolean;
  diagonalScrolling: boolean;
  reverseScrolling: boolean;
  teardropTimeout: number;
  teardropSize: number;
  scrollSpeed: number;
  customTheme: any; // This is a ThemeBuilder JSON, will be typed when ThemeBuilder is fully typed
  relativeLineNumbers: boolean;
  elasticTabstops: boolean;
  rtlText: boolean;
  hardWrap: boolean;
  useTextareaForIME: boolean;
  touchMoveThreshold: number;
  quicktoolsItems: number[];
  excludeFolders: string[];
  defaultFileEncoding: string;
  inlineAutoCompletion: boolean;
  colorPreview: boolean;
  maxRetryCount: number;
  showRetryToast: boolean;
  showSideButtons: boolean;
  showAnnotations: boolean;
  pluginsDisabled: PluginDisabledSettings;
}

interface SettingsPage {
  // This is imported from 'components/settingsPage', will be typed later.
  [key: string]: any;
}

declare class Settings {
  QUICKTOOLS_ROWS: number;
  QUICKTOOLS_GROUP_CAPACITY: number;
  QUICKTOOLS_GROUPS: number;
  QUICKTOOLS_TRIGGER_MODE_TOUCH: string;
  QUICKTOOLS_TRIGGER_MODE_CLICK: string;
  OPEN_FILE_LIST_POS_HEADER: string;
  OPEN_FILE_LIST_POS_SIDEBAR: string;
  OPEN_FILE_LIST_POS_BOTTOM: string;
  KEYBOARD_MODE_NO_SUGGESTIONS: string;
  KEYBOARD_MODE_NO_SUGGESTIONS_AGGRESSIVE: string;
  KEYBOARD_MODE_NORMAL: string;
  CONSOLE_ERUDA: string;
  CONSOLE_LEGACY: string;
  PREVIEW_MODE_INAPP: string;
  PREVIEW_MODE_BROWSER: string;
  uiSettings: { [key: string]: SettingsPage };
  value: AppSettingsValue;

  init(): Promise<void>;
  update(settings?: Partial<AppSettingsValue> | boolean, showToast?: boolean, saveFile?: boolean): Promise<void>;
  reset(setting?: keyof AppSettingsValue): Promise<void | boolean>;
  on(event: `update:${keyof AppSettingsValue}` | `update:${keyof AppSettingsValue}:after` | 'reset', callback: (value: any) => void): void;
  off(event: `update:${keyof AppSettingsValue}` | 'reset', callback: (value: any) => void): void;
  get(key: keyof AppSettingsValue): any; // Can be more specific, but depends on the key
  applyAnimationSetting(): Promise<void>;
  applyLangSetting(): Promise<void>;
}

declare function SideButton(options: SideButtonOptions): SideButtonInstance;

interface SideButtonInstance {
  show(): void;
  hide(): void;
}

interface SideButtonOptions {
  text?: string;
  icon?: string;
  onclick?: () => void;
  backgroundColor?: string;
  textColor?: string;
}

interface FileOptions {
  isUnsaved?: boolean;
  render?: boolean;
  id?: string;
  uri?: string;
  text?: string;
  editable?: boolean;
  deletedFile?: boolean;
  SAFMode?: 'single' | 'tree';
  encoding?: string;
  cursorPos?: { row: number; column: number };
  scrollLeft?: number;
  scrollTop?: number;
  folds?: any[]; // AceAjax.Fold[]
  type?: string; // 'editor' | 'terminal' | custom
  content?: HTMLElement;
  tabIcon?: string;
  hideQuickTools?: boolean;
  stylesheets?: string | string[];
}

type FileEvents = 'run' | 'save' | 'change' | 'focus' | 'blur' | 'close' | 'rename' | 'load' | 'loadError' | 'loadStart' | 'loadEnd' | 'changeMode' | 'changeEncoding' | 'changeReadOnly';

declare class EditorFile {
  constructor(filename?: string, options?: FileOptions);

  // Public properties
  hideQuickTools: boolean;
  stylesheets?: string | string[];
  focusedBefore: boolean;
  focused: boolean;
  loaded: boolean;
  loading: boolean;
  deletedFile: boolean;
  session: AceAjax.IEditSession; // Assuming AceAjax types are available
  encoding: string;
  readOnly: boolean;
  markChanged: boolean;
  isUnsaved: boolean;

  // Getters
  get type(): string;
  get tabIcon(): string;
  get content(): HTMLElement | null;
  get id(): string;
  get filename(): string;
  get location(): string | null;
  get uri(): string | null;
  get eol(): 'windows' | 'unix';
  get editable(): boolean;
  get name(): string; // Deprecated, use filename
  get cacheFile(): string;
  get icon(): string;
  get tab(): HTMLElement;
  get SAFMode(): 'single' | 'tree' | null;

  // Setters
  set id(value: string);
  set filename(value: string);
  set location(value: string);
  set uri(value: string | null);
  set eol(value: 'windows' | 'unix');
  set editable(value: boolean);
  set isUnsaved(value: boolean);

  // Event handlers (publicly exposed for direct assignment)
  onsave?: (event: any) => void;
  onchange?: (event: any) => void;
  onfocus?: (event: any) => void;
  onblur?: (event: any) => void;
  onclose?: (event: any) => void;
  onrename?: (event: any) => void;
  onload?: (event: any) => void;
  onloaderror?: (event: any) => void;
  onloadstart?: (event: any) => void;
  onloadend?: (event: any) => void;
  onchangemode?: (event: any) => void;
  onrun?: (event: any) => void;
  oncanrun?: (event: any) => void;

  // Public methods
  writeToCache(): Promise<void>;
  isChanged(): Promise<boolean>;
  canRun(): Promise<boolean>;
  readCanRun(): Promise<void>;
  writeCanRun(cb: () => boolean | Promise<boolean>): Promise<void>;
  remove(force?: boolean): Promise<void>;
  save(): Promise<boolean>;
  saveAs(): Promise<boolean>;
  setMode(mode?: string): void;
  makeActive(): void;
  removeActive(): void;
  openWith(): void;
  editWith(): void;
  share(): void;
  runAction(): void;
  run(): void;
  runFile(): void;
  render(): void;
  on(event: FileEvents, callback: (this: EditorFile, e: any) => void): void;
  off(event: FileEvents, callback: (this: EditorFile, e: any) => void): void;
  addStyle(style: string): void;
  setCustomTitle(titleFn: () => string): void;
}

interface HintObj {
  value: string;
  text: string;
}

type Hint = HintObj | string;

interface HintModification {
  add(hint: Hint, index?: number): void;
  remove(hint: Hint): void;
  removeIndex(index: number): void;
}

type HintCallback = (setHints: (hints: Hint[]) => void, modification: HintModification) => void;

interface InputHintsResult {
  getSelected(): HTMLLIElement;
  container: HTMLUListElement;
}

declare function inputhints(
  $input: HTMLInputElement,
  hints: Hint[] | HintCallback,
  onSelect?: (value: string) => void
): InputHintsResult;

interface ClipBoard {
  url: string;
  $el: HTMLElement;
  action: 'cut' | 'copy';
}

interface Folder {
  id: string;
  url: string;
  title: string;
  listFiles: boolean;
  saveState: boolean;
  $node: any; // Collapsible
  clipBoard: ClipBoard;
  remove(): void;
  reload(): void;
  listState: Map<string, boolean>;
}

interface OpenFolderOptions {
  name: string;
  id?: string;
  saveState?: boolean;
  listFiles?: boolean;
  listState?: Map<string, boolean>;
}

interface AcodeOpenFolder {
  (path: string, opts?: OpenFolderOptions): void;
  add(url: string, type: 'file' | 'folder'): Promise<void>;
  renameItem(oldFile: string, newFile: string, newFilename: string): void;
  removeItem(url: string): void;
  removeFolders(url: string): void;
  find(url: string): Folder | undefined;
}

interface Action {
  id: string;
  action: () => void;
}

interface AcodeActionStack {
  length: number;
  onCloseApp: (() => void | Promise<void>) | undefined;
  windowCopy(): AcodeActionStack; // Deprecated
  push(fun: Action): void;
  pop(repeat?: number): Promise<void>;
  get(id: string): Action | undefined;
  remove(id: string): boolean;
  has(id: string): boolean;
  setMark(): void;
  clearFromMark(): void;
  freeze(): void;
  unfreeze(): void;
}

interface MultiPromptInput {
  id: string;
  required?: boolean;
  type?: "textarea" | "text" | "number" | "tel" | "search" | "email" | "url" | "filename" | "checkbox" | "radio";
  match?: RegExp;
  value?: string;
  placeholder?: string;
  hints?: any; // This can be Hint[] or HintCallback from inputhints
  name?: string;
  disabled?: boolean;
  onclick?: (this: HTMLInputElement, ev: MouseEvent) => void;
  onchange?: (this: HTMLInputElement, ev: Event) => void;
  readOnly?: boolean;
  autofocus?: boolean;
  hidden?: boolean;
}

declare function multiPrompt(
  message: string,
  inputs: Array<MultiPromptInput | MultiPromptInput[] | string>,
  help?: string
): Promise<{ [id: string]: string | boolean }>;

interface ContextMenuOptions {
  left?: number;
  top?: number;
  bottom?: number;
  right?: number;
  transformOrigin?: string;
  toggler?: HTMLElement;
  onshow?: () => void;
  onhide?: () => void;
  items?: Array<[string, string]>; // Array of [text, action] pairs
  onclick?: (this: HTMLElement, event: MouseEvent) => void;
  onselect?: (item: string) => void;
  innerHTML?: (this: HTMLElement) => string;
}

interface ContextMenuObj extends HTMLElement {
  hide(): void;
  show(): void;
  destroy(): void;
  onshow(): void;
  onhide(): void;
}

declare function Contextmenu(content: string | ContextMenuOptions, options?: ContextMenuOptions): ContextMenuObj;

type BrowseMode = "file" | "folder" | "both";

interface SelectedFile {
  type: 'file' | 'folder';
  url: string;
  name: string;
}

interface AcodeFileBrowser {
  /**
   * @param mode Specify file browser mode, value can be 'file', 'folder' or 'both'
   * @param info A small message to show what's file browser is opened for
   * @param doesOpenLast Should file browser open lastly visited directory?
   * @param defaultDir Default directory to open.
   * @returns {Promise<SelectedFile>}
   */
  (mode?: BrowseMode, info?: string, doesOpenLast?: boolean, ...defaultDir: Array<{ name: string; url: string }>): Promise<SelectedFile>;
  openFile(res: { url: string; name: string; mode?: string }): void;
  openFileError(err: any): void;
  openFolder(res: { url: string; name: string }): Promise<void>;
  openFolderError(err: any): void;
  open(res: { type: 'file' | 'folder'; url: string; name: string; mode?: string }): void;
  openError(err: any): void;
}

type KeyboardEventName = 'key' | 'keyboardShow' | 'keyboardHide' | 'keyboardShowStart' | 'keyboardHideStart';

interface AcodeKeyboardHandler {
  (e: KeyboardEvent): void;
  on(eventName: KeyboardEventName, callback: () => void): void;
  off(eventName: KeyboardEventName, callback: () => void): void;
  keydownState: {
    esc: boolean;
  };
}

type ResizeEventName = 'resize' | 'resizeStart';

interface AcodeWindowResize {
  (): void;
  on(eventName: ResizeEventName, callback: () => void): void;
  off(eventName: ResizeEventName, callback: () => void): void;
}

interface Encoding {
  label: string;
  aliases: string[];
  name: string;
}

interface AcodeEncodings {
  encodings: { [key: string]: Encoding };
  encode(text: string, charset: string): Promise<ArrayBuffer>;
  decode(buffer: ArrayBuffer, charset?: string): Promise<string | object>;
}

interface SelectionMenuItem {
  onclick: Function;
  text: string | HTMLElement;
  mode: 'selected' | 'all';
  readOnly: boolean;
}

interface AcodeSelectionMenu {
  (): SelectionMenuItem[];
  add(onclick: Function, text: string | HTMLElement, mode: 'selected' | 'all', readOnly?: boolean): void;
  exec(command: string): void;
}

interface SidebarAppInstance {
  id: string;
  active: boolean;
  container: HTMLElement;
  install(prepend: boolean): void;
  remove(): void;
}

interface AcodeSidebarApps {
  init($el: HTMLElement): void;
  add(
    icon: string,
    id: string,
    title: string,
    initFunction: (container: HTMLElement) => void,
    prepend?: boolean,
    onSelected?: (container: HTMLElement) => void
  ): void;
  get(id: string): HTMLElement;
  remove(id: string): void;
  loadApps(): Promise<void>;
}

interface TerminalTheme {
  name: string;
  background: string;
  foreground: string;
  cursor: string;
  cursorAccent: string;
  selection: string;
  black: string;
  red: string;
  green: string;
  yellow: string;
  blue: string;
  magenta: string;
  cyan: string;
  white: string;
  brightBlack: string;
  brightRed: string;
  brightGreen: string;
  brightYellow: string;
  brightBlue: string;
  brightMagenta: string;
  brightCyan: string;
  brightWhite: string;
}

interface TerminalInstance {
  id: string;
  write(data: string): void;
  clear(): void;
  dispose(): void;
}

interface AcodeTerminal {
  create(options?: any): TerminalInstance;
  createLocal(options?: any): TerminalInstance;
  createServer(options?: any): TerminalInstance;
  get(id: string): TerminalInstance | undefined;
  getAll(): TerminalInstance[];
  write(id: string, data: string): void;
  clear(id: string): void;
  close(id: string): void;
  themes: {
    register(name: string, theme: TerminalTheme, pluginId: string): void;
    unregister(name: string, pluginId: string): void;
    get(name: string): TerminalTheme | undefined;
    getAll(): TerminalTheme[];
    getNames(): string[];
    createVariant(baseName: string, overrides: Partial<TerminalTheme>): TerminalTheme;
  };
}

interface KeyEventDict {
  type?: 'keydown' | 'keypress' | 'keyup';
  bubbles?: boolean;
  cancelable?: boolean;
  which?: number;
  keyCode?: number;
  key?: string;
  ctrlKey?: boolean;
  shiftKey?: boolean;
  altKey?: boolean;
  metaKey?: boolean;
}

declare function KeyboardEvent(type: 'keydown' | 'keyup', dict: KeyEventDict): globalThis.KeyboardEvent;

declare class Acode {
  /**
   * Define a module that can be accessed with `acode.require()`.
   * @param name The name of the module.
   * @param module The module object or function.
   */
  define<T extends keyof AcodeModules>(name: T, module: AcodeModules[T]): void;

  /**
   * Require a module defined by `acode.define()`.
   * @param module The name of the module to require.
   */
  require<T extends keyof AcodeModules>(module: T): AcodeModules[T];

  /**
   * Execute a command.
   * @param key The command to execute.
   * @param val An optional value to pass to the command.
   */
  exec(key: string, val?: any): any;

  /**
   * Installs an Acode plugin from the registry.
   * @param pluginId ID of the plugin to install.
   * @param installerPluginName Name of the plugin attempting to install.
   */
  installPlugin(pluginId: string, installerPluginName?: string): Promise<void>;

  /**
   * A message to show when the user tries to exit the app with unsaved files.
   */
  get exitAppMessage(): string | null;

  /**
   * Sets the loading message on the splash screen.
   * @param message The message to display.
   */
  setLoadingMessage(message: string): void;

  /**
   * Sets the initialization function for a plugin.
   * @param id The plugin's ID.
   * @param initFunction The function to call when the plugin is initialized.
   * @param settings Plugin settings UI configuration.
   */
  setPluginInit(
    id: string,
    initFunction: (baseUrl: string, $page: HTMLElement, options: any) => void | Promise<void>,
    settings?: { list: any[], cb: (key: string, value: any) => void }
  ): void;

  /**
   * Sets the unmount function for a plugin.
   * @param id The plugin's ID.
   * @param unmountFunction The function to call when the plugin is unmounted.
   */
  setPluginUnmount(id: string, unmountFunction: () => void): void;

  /**
   * Initializes a plugin.
   * @param id The plugin's ID.
   * @param baseUrl The base URL for the plugin's assets.
   * @param $page The plugin's main page element.
   * @param options Plugin options.
   */
  initPlugin(id: string, baseUrl: string, $page: HTMLElement, options: any): Promise<void>;

  /**
   * Unmounts a plugin.
   * @param id The plugin's ID.
   */
  unmountPlugin(id: string): void;

  /**
   * Registers a code formatter.
   * @param id A unique ID for the formatter.
   * @param extensions An array of file extensions this formatter can handle.
   * @param format The formatting function.
   */
  registerFormatter(id: string, extensions: string[], format: () => void | Promise<void>): void;

  /**
   * Unregisters a code formatter.
   * @param id The ID of the formatter to remove.
   */
  unregisterFormatter(id: string): void;

  /**
   * Formats the code in the active editor session.
   * @param selectIfNull If true, prompts the user to select a formatter if none is set for the current file type.
   */
  format(selectIfNull?: boolean): Promise<void>;

  /**
   * Get a file system operation object for a given path.
   * @param file The file path.
   */
  fsOperation(file: string): any;

  /**
   * Creates a new editor file.
   * @param filename The name of the file.
   * @param options Options for the new file.
   */
  newEditorFile(filename: string, options?: any): void;

  /**
   * A list of all registered formatters.
   */
  get formatters(): Array<{ id: string, name: string, exts: string[] }>;

  /**
   * Gets a list of formatters compatible with the given file extensions.
   * @param extensions An array of file extensions.
   * @returns An array of [id, name] tuples.
   */
  getFormatterFor(extensions: string[]): Array<[string | null, string]>;

  /**
   * Shows an alert dialog.
   * @param title The title of the alert.
   * @param message The message body.
   * @param onhide A callback function to execute when the dialog is hidden.
   */
  alert(title: string, message: string, onhide?: () => void): void;

  /**
   * Creates and shows a loader.
   * @param title The title for the loader.
   * @param message The message body.
   * @param cancel A cancellation configuration object.
   */
  loader(title: string, message: string, cancel?: { id: string, call: () => void }): any;

  /**
   * Joins URL parts into a single URL.
   * @param args URL parts to join.
   */
  joinUrl(...args: string[]): string;

  /**
   * Adds a custom icon to be used in the app.
   * @param className The CSS class name for the icon.
   * @param src: string): void;

  /**
   * Shows a prompt dialog.
   * @param message The message to display in the prompt.
   * @param defaultValue The default value for the input field.
   * @param type The type of input (e.g., 'text', 'number').
   * @param options Additional options for the prompt.
   */
  prompt(message: string, defaultValue?: string, type?: string, options?: any): Promise<string | null>;

  /**
   * Shows a confirmation dialog.
   * @param title The title of the dialog.
   * @param message The confirmation message.
   */
  confirm(title: string, message: string): Promise<boolean>;

  /**
   * Shows a selection dialog.
   * @param title The title of the dialog.
   * @param options The options to choose from.
   * @param config Configuration for the selection dialog.
   */
  select(title: string, options: any, config?: any): Promise<any>;

  /**
   * Shows a dialog with multiple input fields.
   * @param title The title of the dialog.
   * @param inputs An array of input configurations.
   * @param help A help message or URL.
   */
  multiPrompt(title: string, inputs: any[], help?: string): Promise<any>;

  /**
   * Opens the file browser.
   * @param mode The browsing mode ('file', 'folder', or 'both').
   * @param info An informational message to display.
   * @param openLast Whether to open the last visited location.
   */
  fileBrowser(mode: 'file' | 'folder' | 'both', info?: string, openLast?: boolean): Promise<any>;

  /**
   * Converts a content URI to an internal URL.
   * @param url The content URI to convert.
   */
  toInternalUrl(url: string): Promise<string>;

  /**
   * Pushes a notification to the user.
   * @param title The title of the notification.
   * @param message The message body.
   * @param options Notification options.
   */
  pushNotification(
    title: string,
    message: string,
    options?: {
      icon?: string;
      autoClose?: boolean;
      action?: Function;
      type?: 'info' | 'warning' | 'error' | 'success';
    }
  ): void;

  /**
   * Registers a custom file handler.
   * @param id A unique ID for the handler.
   * @param options Handler configuration.
   */
  registerFileHandler(id: string, options: { extensions: string[], handleFile: (file: any) => void }): void;

  /**
   * Unregisters a file handler.
   * @param id The ID of the handler to remove.
   */
  unregisterFileHandler(id: string): void;
}

declare const acode: Acode;

export default Acode;