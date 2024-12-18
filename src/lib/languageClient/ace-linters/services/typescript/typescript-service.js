import { BaseService } from "../base-service";
import * as ts from './lib/typescriptServices';
import { libFileMap } from "./lib/lib";
import { diagnosticsToErrorCodes, fromTsDiagnostics, getTokenModifierFromClassification, getTokenTypeFromClassification, JsxEmit, ScriptTarget, SemanticClassificationFormat, toCodeActions, toCompletions, toDocumentHighlights, toHover, toResolvedCompletion, toSignatureHelp, toTextEdits, toTextSpan, toTsOffset } from "./typescript-converters";
import { mergeObjects } from "../../utils";
import { SemanticTokensBuilder } from "../../type-converters/lsp/semantic-tokens";
export class TypescriptService extends BaseService {
    constructor(mode) {
        super(mode);
        this.$defaultCompilerOptions = {
            allowJs: true,
            checkJs: true,
            jsx: JsxEmit.Preserve,
            allowNonTsExtensions: true,
            target: ScriptTarget.ES2020,
            noSemanticValidation: true,
            noSyntaxValidation: false,
            onlyVisible: false,
            module: 99,
            moduleResolution: 99,
            allowSyntheticDefaultImports: true,
            moduleDetection: 3
        };
        this.$defaultFormatOptions = {
            insertSpaceAfterCommaDelimiter: true,
            insertSpaceAfterSemicolonInForStatements: true,
            insertSpaceBeforeAndAfterBinaryOperators: true,
            insertSpaceAfterConstructor: false,
            insertSpaceAfterKeywordsInControlFlowStatements: true,
            insertSpaceAfterFunctionKeywordForAnonymousFunctions: true,
            insertSpaceAfterOpeningAndBeforeClosingNonemptyParenthesis: false,
            insertSpaceAfterOpeningAndBeforeClosingNonemptyBrackets: false,
            insertSpaceAfterOpeningAndBeforeClosingNonemptyBraces: true,
            insertSpaceAfterOpeningAndBeforeClosingEmptyBraces: true,
            insertSpaceAfterOpeningAndBeforeClosingTemplateStringBraces: false,
            insertSpaceAfterOpeningAndBeforeClosingJsxExpressionBraces: false,
            insertSpaceAfterTypeAssertion: false,
            insertSpaceBeforeFunctionParenthesis: false,
            placeOpenBraceOnNewLineForFunctions: false,
            placeOpenBraceOnNewLineForControlBlocks: false,
            indentSize: 4,
            tabSize: 4,
            newLineCharacter: "\n",
            convertTabsToSpaces: true,
        };
        this.serviceCapabilities = {
            completionProvider: {
                triggerCharacters: ['.', '"', '\'', '`', '/', '@', '<', '#']
            },
            diagnosticProvider: {
                interFileDependencies: true,
                workspaceDiagnostics: true
            },
            documentRangeFormattingProvider: true,
            documentFormattingProvider: true,
            documentHighlightProvider: true,
            hoverProvider: true,
            signatureHelpProvider: {},
            semanticTokensProvider: {
                legend: {
                    tokenTypes: ['class', 'enum', 'interface', 'namespace', 'typeParameter', 'type', 'parameter', 'variable', 'enumMember', 'property', 'function', 'method'],
                    tokenModifiers: ['async', 'declaration', 'readonly', 'static', 'local', 'defaultLibrary']
                },
                range: true,
                full: true
            },
            codeActionProvider: true,
        };
        this.$service = ts.createLanguageService(this);
    }
    getCompilationSettings() {
        var _a;
        const parseConfigHost = {
            fileExists: () => {
                return true;
            },
            readFile: () => {
                return "";
            },
            readDirectory: () => {
                return [];
            },
            useCaseSensitiveFileNames: true
        };
        let options = ts.parseJsonConfigFileContent(this.globalOptions, parseConfigHost, "");
        options = mergeObjects(options.options, (_a = this.globalOptions) === null || _a === void 0 ? void 0 : _a.compilerOptions, true);
        return mergeObjects(options, this.$defaultCompilerOptions);
    }
    getScriptFileNames() {
        let fileNames = Object.keys(this.documents);
        return fileNames.concat(Object.keys(this.$extraLibs));
    }
    get $extraLibs() {
        var _a;
        return (_a = this.globalOptions["extraLibs"]) !== null && _a !== void 0 ? _a : [];
    }
    getScriptVersion(fileName) {
        let document = this.getDocument(fileName);
        if (document) {
            if (document.version)
                return document["version"].toString();
            else
                return "1";
        }
        else if (fileName === this.getDefaultLibFileName(this.getCompilationSettings())) {
            return '1';
        }
        return '';
    }
    getScriptSnapshot(fileName) {
        const text = this.$getDocument(fileName);
        if (text === undefined) {
            return;
        }
        return {
            getText: (start, end) => text.substring(start, end),
            getLength: () => text.length,
            getChangeRange: () => undefined
        };
    }
    $getDocument(fileName) {
        var _a;
        const fileNameWithoutUri = fileName.replace("file:///", "");
        let document = (_a = this.getDocument(fileName)) !== null && _a !== void 0 ? _a : this.getDocument(fileNameWithoutUri);
        if (document) {
            return document.getText();
        }
        if (fileName in libFileMap) {
            return libFileMap[fileName];
        }
        if (fileName in this.$extraLibs) {
            return this.$extraLibs[fileName].content;
        }
        if (fileNameWithoutUri in this.$extraLibs) {
            return this.$extraLibs[fileNameWithoutUri].content;
        }
        return;
    }
    getScriptKind(fileName) {
        const ext = fileName.substring(fileName.lastIndexOf('.') + 1);
        switch (ext) {
            case 'ts':
                return ts.ScriptKind.TS;
            case 'tsx':
                return ts.ScriptKind.TSX;
            case 'js':
                return ts.ScriptKind.JS;
            case 'jsx':
                return ts.ScriptKind.JSX;
            case 'json':
                return ts.ScriptKind.JSON;
            default:
                return this.getCompilationSettings().allowJs ? ts.ScriptKind.JS : ts.ScriptKind.TS;
        }
    }
    getCurrentDirectory() {
        return '';
    }
    getDefaultLibFileName(options) {
        switch (options.target) {
            case ScriptTarget.ESNext:
                return 'lib.esnext.full.d.ts';
            case ScriptTarget.ES3:
            case ScriptTarget.ES5:
                return 'lib.d.ts';
            default:
                // Support a dynamic lookup for the ES20XX version based on the target
                // which is safe unless TC39 changes their numbering system
                const eslib = `lib.es${2013 + (options.target || 99)}.full.d.ts`;
                // Note: This also looks in _extraLibs, If you want
                // to add support for additional target options, you will need to
                // add the extra dts files to _extraLibs via the API.
                if (eslib in libFileMap /*|| eslib in this._extraLibs*/) {
                    return eslib;
                }
                return 'lib.es6.d.ts'; // We don't use lib.es2015.full.d.ts due to breaking change.
        }
    }
    readFile(path) {
        return this.$getDocument(path);
    }
    fileExists(path) {
        return this.$getDocument(path) !== undefined;
    }
    getSyntacticDiagnostics(fileName) {
        return this.$service.getSyntacticDiagnostics(fileName);
    }
    getSemanticDiagnostics(fileName) {
        return this.$service.getSemanticDiagnostics(fileName);
    }
    getFormattingOptions(options) {
        this.$defaultFormatOptions.convertTabsToSpaces = options.insertSpaces;
        this.$defaultFormatOptions.tabSize = options.tabSize;
        this.$defaultFormatOptions.indentSize = options.tabSize;
        if (this.globalOptions && this.globalOptions["formatOptions"]) {
            return mergeObjects(this.globalOptions["formatOptions"], this.$defaultFormatOptions);
        }
        return this.$defaultFormatOptions;
    }
    format(document, range, options) {
        let fullDocument = this.getDocument(document.uri);
        if (!fullDocument || !range)
            return Promise.resolve([]);
        let offset = toTsOffset(range, fullDocument);
        let textEdits = this.$service.getFormattingEditsForRange(document.uri, offset.start, offset.end, this.getFormattingOptions(options));
        return Promise.resolve(toTextEdits(textEdits, fullDocument));
    }
    async doHover(document, position) {
        let fullDocument = this.getDocument(document.uri);
        if (!fullDocument)
            return null;
        let hover = this.$service.getQuickInfoAtPosition(document.uri, fullDocument.offsetAt(position) + 1);
        return toHover(hover, fullDocument);
    }
    //TODO: more validators?
    async doValidation(document) {
        let fullDocument = this.getDocument(document.uri);
        if (!fullDocument)
            return [];
        let semanticDiagnostics = this.getSemanticDiagnostics(document.uri);
        let syntacticDiagnostics = this.getSyntacticDiagnostics(document.uri);
        return fromTsDiagnostics([...syntacticDiagnostics, ...semanticDiagnostics], fullDocument, this.optionsToFilterDiagnostics);
    }
    async doComplete(document, position) {
        let fullDocument = this.getDocument(document.uri);
        if (!fullDocument)
            return null;
        let offset = fullDocument.offsetAt(position);
        let completions = this.$service.getCompletionsAtPosition(document.uri, offset, undefined);
        if (!completions)
            return null;
        return toCompletions(completions, fullDocument, offset);
    }
    async doResolve(item) {
        let resolvedCompletion = this.$service.getCompletionEntryDetails(item["fileName"], item["position"], item.label, undefined, undefined, undefined, undefined);
        if (!resolvedCompletion)
            return null;
        return toResolvedCompletion(resolvedCompletion);
    }
    async provideSignatureHelp(document, position) {
        let fullDocument = this.getDocument(document.uri);
        if (!fullDocument)
            return null;
        let offset = fullDocument.offsetAt(position);
        //TODO: options
        return toSignatureHelp(this.$service.getSignatureHelpItems(document.uri, offset, undefined));
    }
    ;
    async findDocumentHighlights(document, position) {
        let fullDocument = this.getDocument(document.uri);
        if (!fullDocument)
            return [];
        let offset = fullDocument.offsetAt(position);
        //TODO: this could work with all opened documents
        let highlights = this.$service.getDocumentHighlights(document.uri, offset, [document.uri]);
        return toDocumentHighlights(highlights, fullDocument);
    }
    async getSemanticTokens(document, range) {
        let fullDocument = this.getDocument(document.uri);
        if (!fullDocument)
            return null;
        let classifications = this.$service.getEncodedSemanticClassifications(document.uri, toTextSpan(range, fullDocument), SemanticClassificationFormat.TwentyTwenty);
        if (!classifications) {
            return null;
        }
        let tokensSpans = classifications.spans;
        const builder = new SemanticTokensBuilder();
        for (let i = 0; i < tokensSpans.length;) {
            const offset = tokensSpans[i++];
            const length = tokensSpans[i++];
            const tsClassification = tokensSpans[i++];
            const tokenType = getTokenTypeFromClassification(tsClassification);
            if (tokenType === undefined) {
                continue;
            }
            const tokenModifiers = getTokenModifierFromClassification(tsClassification);
            const startPos = fullDocument.positionAt(offset);
            const endPos = fullDocument.positionAt(offset + length);
            for (let line = startPos.line; line <= endPos.line; line++) {
                const startCharacter = (line === startPos.line ? startPos.character : 0);
                let textOnLine = fullDocument.getText({
                    start: { line: line, character: 0 },
                    end: { line: line, character: Infinity }
                });
                const endCharacter = (line === endPos.line ? endPos.character : textOnLine.length);
                builder.push(line, startCharacter, endCharacter - startCharacter, tokenType, tokenModifiers);
            }
        }
        return builder.build();
    }
    getCodeActions(document, range, context) {
        let fullDocument = this.getDocument(document.uri);
        if (!fullDocument)
            return Promise.resolve(null);
        let offset = toTsOffset(range, fullDocument);
        let codeErrors = diagnosticsToErrorCodes(context.diagnostics);
        return Promise.resolve(toCodeActions(this.$service.getCodeFixesAtPosition(document.uri, offset.start, offset.end, codeErrors, this.$defaultFormatOptions, {}), fullDocument));
    }
}
//# sourceMappingURL=typescript-service.js.map