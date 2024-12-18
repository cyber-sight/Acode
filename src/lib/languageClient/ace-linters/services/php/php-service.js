import { BaseService } from "../base-service.js";
import { PHP } from "./lib/php.js";
import { filterDiagnostics } from "../../type-converters/lsp-converters.js";
export class PhpService extends BaseService {
    $service;
    serviceCapabilities = {
        diagnosticProvider: {
            interFileDependencies: true,
            workspaceDiagnostics: true
        }
    };
    constructor(mode) {
        super(mode);
    }
    async doValidation(document) {
        let value = this.getDocumentValue(document.uri);
        if (!value)
            return [];
        if (this.getOption(document.uri, "inline")) {
            value = "<?" + value + "?>";
        }
        var tokens = PHP.Lexer(value, { short_open_tag: 1 });
        let errors = [];
        try {
            new PHP.Parser(tokens);
        }
        catch (e) {
            errors.push({
                range: {
                    start: {
                        line: e.line - 1,
                        character: 0
                    },
                    end: {
                        line: e.line - 1,
                        character: 0
                    }
                },
                message: e.message.charAt(0).toUpperCase() + e.message.substring(1),
                severity: 1
            });
        }
        return filterDiagnostics(errors, this.optionsToFilterDiagnostics);
    }
}
