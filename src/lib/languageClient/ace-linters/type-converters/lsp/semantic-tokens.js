"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.SemanticTokensBuilder = exports.DecodedSemanticTokens = void 0;
exports.parseSemanticTokens = parseSemanticTokens;
exports.mergeTokens = mergeTokens;
function decodeModifiers(modifierFlag, tokenModifiersLegend) {
    const modifiers = [];
    for (let i = 0; i < tokenModifiersLegend.length; i++) {
        if (modifierFlag & (1 << i)) {
            modifiers.push(tokenModifiersLegend[i]);
        }
    }
    return modifiers;
}
function parseSemanticTokens(tokens, tokenTypes, tokenModifiersLegend) {
    if (tokens.length % 5 !== 0) {
        return;
    }
    const decodedTokens = [];
    let line = 0;
    let startColumn = 0;
    for (let i = 0; i < tokens.length; i += 5) {
        line += tokens[i];
        if (tokens[i] === 0) {
            startColumn += tokens[i + 1];
        }
        else {
            startColumn = tokens[i + 1];
        }
        const length = tokens[i + 2];
        const tokenTypeIndex = tokens[i + 3];
        const tokenModifierFlag = tokens[i + 4];
        const tokenType = tokenTypes[tokenTypeIndex];
        const tokenModifiers = decodeModifiers(tokenModifierFlag, tokenModifiersLegend);
        decodedTokens.push({
            row: line,
            startColumn: startColumn,
            length,
            type: toAceTokenType(tokenType, tokenModifiers),
        });
    }
    return new DecodedSemanticTokens(decodedTokens);
}
function toAceTokenType(tokenType, tokenModifiers) {
    let modifiers = "";
    let type = tokenType;
    if (tokenModifiers.length > 0) {
        modifiers = "." + tokenModifiers.join(".");
    }
    switch (tokenType) {
        case "class":
            type = "entity.name.type.class";
            break;
        case "struct":
            type = "storage.type.struct";
            break;
        case "enum":
            type = "entity.name.type.enum";
            break;
        case "interface":
            type = "entity.name.type.interface";
            break;
        case "namespace":
            type = "entity.name.namespace";
            break;
        case "typeParameter":
            break;
        case "type":
            type = "entity.name.type";
            break;
        case "parameter":
            type = "variable.parameter";
            break;
        case "variable":
            type = "entity.name.variable";
            break;
        case "enumMember":
            type = "variable.other.enummember";
            break;
        case "property":
            type = "variable.other.property";
            break;
        case "function":
            type = "entity.name.function";
            break;
        case "method":
            type = "entity.name.function.member";
            break;
        case "event":
            type = "variable.other.event";
            break;
    }
    return type + modifiers;
}
function mergeTokens(aceTokens, decodedTokens) {
    let mergedTokens = [];
    let currentCharIndex = 0; // Keeps track of the character index across Ace tokens
    let aceTokenIndex = 0; // Index within the aceTokens array
    decodedTokens.forEach((semanticToken) => {
        let semanticStart = semanticToken.startColumn;
        let semanticEnd = semanticStart + semanticToken.length;
        // Process leading Ace tokens that don't overlap with the semantic token
        while (aceTokenIndex < aceTokens.length && currentCharIndex + aceTokens[aceTokenIndex].value.length <= semanticStart) {
            mergedTokens.push(aceTokens[aceTokenIndex]);
            currentCharIndex += aceTokens[aceTokenIndex].value.length;
            aceTokenIndex++;
        }
        // Process overlapping Ace tokens
        while (aceTokenIndex < aceTokens.length && currentCharIndex < semanticEnd) {
            let aceToken = aceTokens[aceTokenIndex];
            let aceTokenEnd = currentCharIndex + aceToken.value.length;
            let overlapStart = Math.max(currentCharIndex, semanticStart);
            let overlapEnd = Math.min(aceTokenEnd, semanticEnd);
            if (currentCharIndex < semanticStart) {
                // Part of Ace token is before semantic token; add this part to mergedTokens
                let beforeSemantic = {
                    ...aceToken,
                    value: aceToken.value.substring(0, semanticStart - currentCharIndex)
                };
                mergedTokens.push(beforeSemantic);
            }
            // Middle part (overlapped by semantic token)
            let middle = {
                type: semanticToken.type, // Use semantic token's type
                value: aceToken.value.substring(overlapStart - currentCharIndex, overlapEnd - currentCharIndex)
            };
            mergedTokens.push(middle);
            if (aceTokenEnd > semanticEnd) {
                // If Ace token extends beyond the semantic token, prepare the remaining part for future processing
                let afterSemantic = {
                    ...aceToken,
                    value: aceToken.value.substring(semanticEnd - currentCharIndex)
                };
                // Add the afterSemantic as a new token to process in subsequent iterations
                currentCharIndex = semanticEnd; // Update currentCharIndex to reflect the start of afterSemantic
                aceTokens.splice(aceTokenIndex, 1, afterSemantic); // Replace the current token with afterSemantic for correct processing in the next iteration
                break; // Move to the next semantic token without incrementing aceTokenIndex
            }
            // If the entire Ace token is covered by the semantic token, proceed to the next Ace token
            currentCharIndex = aceTokenEnd;
            aceTokenIndex++;
        }
    });
    // Add remaining Ace tokens that were not overlapped by any semantic tokens
    while (aceTokenIndex < aceTokens.length) {
        mergedTokens.push(aceTokens[aceTokenIndex]);
        aceTokenIndex++;
    }
    return mergedTokens;
}
class DecodedSemanticTokens {
    constructor(tokens) {
        this.tokens = this.sortTokens(tokens);
    }
    getByRow(row) {
        return this.tokens.filter(token => token.row === row);
    }
    sortTokens(tokens) {
        return tokens.sort((a, b) => {
            if (a.row === b.row) {
                return a.startColumn - b.startColumn;
            }
            return a.row - b.row;
        });
    }
}
exports.DecodedSemanticTokens = DecodedSemanticTokens;
//vscode-languageserver
class SemanticTokensBuilder {
    constructor() {
        this._prevData = undefined;
        this.initialize();
    }
    initialize() {
        this._id = Date.now();
        this._prevLine = 0;
        this._prevChar = 0;
        this._data = [];
        this._dataLen = 0;
    }
    push(line, char, length, tokenType, tokenModifiers) {
        let pushLine = line;
        let pushChar = char;
        if (this._dataLen > 0) {
            pushLine -= this._prevLine;
            if (pushLine === 0) {
                pushChar -= this._prevChar;
            }
        }
        this._data[this._dataLen++] = pushLine;
        this._data[this._dataLen++] = pushChar;
        this._data[this._dataLen++] = length;
        this._data[this._dataLen++] = tokenType;
        this._data[this._dataLen++] = tokenModifiers;
        this._prevLine = line;
        this._prevChar = char;
    }
    get id() {
        return this._id.toString();
    }
    previousResult(id) {
        if (this.id === id) {
            this._prevData = this._data;
        }
        this.initialize();
    }
    build() {
        this._prevData = undefined;
        return {
            resultId: this.id,
            data: this._data
        };
    }
    canBuildEdits() {
        return this._prevData !== undefined;
    }
}
exports.SemanticTokensBuilder = SemanticTokensBuilder;
//# sourceMappingURL=semantic-tokens.js.map