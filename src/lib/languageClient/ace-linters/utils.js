export function mergeObjects(obj1, obj2) {
    if (!obj1)
        return obj2;
    if (!obj2)
        return obj1;
    const mergedObjects = { ...obj2, ...obj1 };
    for (const key of Object.keys(mergedObjects)) {
        if (obj1[key] && obj2[key]) {
            if (Array.isArray(obj1[key])) {
                mergedObjects[key] = obj1[key].concat(obj2[key]);
            }
            else if (Array.isArray(obj2[key])) {
                mergedObjects[key] = obj2[key].concat(obj1[key]);
            }
            else if (typeof obj1[key] === 'object' && typeof obj2[key] === 'object') {
                mergedObjects[key] = mergeObjects(obj1[key], obj2[key]);
            }
        }
    }
    return mergedObjects;
}
export function notEmpty(value) {
    return value !== null && value !== undefined;
}
export function mergeRanges(ranges) {
    var list = ranges;
    list = list.sort(function (a, b) {
        return comparePoints(a.start, b.start);
    });
    var next = list[0], range;
    for (var i = 1; i < list.length; i++) {
        range = next;
        next = list[i];
        var cmp = comparePoints(range.end, next.start);
        if (cmp < 0)
            continue;
        if (cmp == 0 && !range.isEmpty() && !next.isEmpty())
            continue;
        if (comparePoints(range.end, next.end) < 0) {
            range.end.row = next.end.row;
            range.end.column = next.end.column;
        }
        list.splice(i, 1);
        next = range;
        i--;
    }
    return list;
}
function comparePoints(p1, p2) {
    return p1.row - p2.row || p1.column - p2.column;
}
export function checkValueAgainstRegexpArray(value, regexpArray) {
    if (!regexpArray) {
        return false;
    }
    for (let i = 0; i < regexpArray.length; i++) {
        if (regexpArray[i].test(value)) {
            return true;
        }
    }
    return false;
}
