// [CE-EE] F09 P2: nanoid v5 is ESM-only and ts-jest (isolatedModules) cannot
// parse it when a spec's import chain reaches columns.service. Auto-mock with
// a deterministic id.
module.exports = {
  customAlphabet:
    (alphabet = 'abcdefghijklmnopqrstuvwxyz') =>
    (size = 21) =>
      Array.from({ length: size }, (_, i) => alphabet[i % alphabet.length]).join(''),
  nanoid: (size = 21) => 'x'.repeat(size),
}
