import { DiagnosticSeverity } from "vscode-languageserver-protocol";
import { CommonConverter } from "../../type-converters/common-converters";
import { checkValueAgainstRegexpArray } from "../../utils";
export function toDiagnostic(error, filterErrors) {
    let severity;
    if (checkValueAgainstRegexpArray(error.message, filterErrors.errorMessagesToTreatAsWarning)) {
        severity = DiagnosticSeverity.Warning;
    }
    else if (checkValueAgainstRegexpArray(error.message, filterErrors.errorMessagesToTreatAsInfo)) {
        severity = DiagnosticSeverity.Information;
    }
    else {
        severity = (error.fatal) ? DiagnosticSeverity.Error : error.severity;
    }
    return {
        message: error.message,
        range: {
            start: {
                line: error.line - 1,
                character: error.column - 1
            },
            end: {
                line: error.endLine - 1,
                character: error.endColumn - 1
            }
        },
        severity: severity,
    };
}
export function toDiagnostics(diagnostics, filterErrors) {
    if (!diagnostics) {
        return [];
    }
    return CommonConverter.excludeByErrorMessage(diagnostics).map((error) => toDiagnostic(error, filterErrors));
}
