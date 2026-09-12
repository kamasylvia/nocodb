// [CE-EE] F05 R4: root entry so a bare `pnpm vitest run` picks up the test
// configuration (aliases/globals) — the canonical config lives in test/
import config from './test/vite.config'

export default config
