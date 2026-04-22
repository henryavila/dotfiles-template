#!/usr/bin/env bash
# assets/previews/setup-demo.sh — scaffold a realistic full-stack project
# under /tmp/p10k-demo so every Powerlevel10k segment your config can
# render has something to show.
#
# After running, cd in and take a screenshot. See assets/previews/README.md
# for the exact capture recipe (terminal size, commands to run).
#
# What the generated repo triggers in p10k:
#   - os_icon              always on
#   - dir                  nested paths → truncation, dotted separators
#   - vcs                  branch name (not main), staged/unstaged/untracked
#                          counters, AND GitHub icon (remote URL points at
#                          github.com, which p10k detects via the vcs segment)
#   - command_execution_time → precede capture with `sleep 2` if your config
#                          shows this segment (the config here does)
#   - direnv               .envrc in the root (segment only lights up if
#                          `direnv` is installed)
#   - asdf                 .tool-versions in the root (ditto for asdf)
#   - nodenv / nvm         .node-version in the root (ditto for either)
#   - virtualenv / pyenv   .python-version in the root
#
# Also creates enough files in subdirectories that `TAB` completion on a
# partial path shows a real directory listing in fzf-tab's preview pane —
# good for a second screenshot showing the completion stack.

set -euo pipefail

DEMO_DIR="${1:-/tmp/p10k-demo}"

rm -rf "$DEMO_DIR"
mkdir -p "$DEMO_DIR"/{.github/{workflows,ISSUE_TEMPLATE},src/{components,hooks,utils,types},tests/{components,utils},docs/images,public,scripts}

cd "$DEMO_DIR"
git init --initial-branch=main --quiet

# Seed identity if missing (needed for commits)
if ! git config user.name >/dev/null 2>&1; then
    git config user.name "Preview Bot"
    git config user.email "preview@example.local"
fi

# ─── Dev-environment markers (trigger p10k version segments) ─────────
cat > .envrc <<'EOF'
# Picked up by direnv if installed — p10k shows a ✓ when it's allowed.
export DEMO_ENV=1
export DATABASE_URL="postgres://localhost/demo_dev"
EOF

cat > .node-version <<'EOF'
20.11.1
EOF

cat > .python-version <<'EOF'
3.13.2
EOF

cat > .tool-versions <<'EOF'
nodejs 20.11.1
python 3.13.2
ruby 3.3.0
EOF

# ─── Root project files ──────────────────────────────────────────────
cat > README.md <<'EOF'
# awesome-app

Demo full-stack app for capturing Powerlevel10k screenshots.

## Stack

- TypeScript + React on the frontend
- Node 20 LTS + Express API
- PostgreSQL 16 + Redis
- Vitest + Playwright for tests
- Docker Compose for local dev orchestration

## Quickstart

```bash
pnpm install
docker compose up -d
pnpm dev
```

See `docs/` for architecture notes.
EOF

cat > LICENSE <<'EOF'
MIT License

Copyright (c) 2026 demo

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions: […]
EOF

cat > .gitignore <<'EOF'
node_modules/
dist/
.env
.env.local
coverage/
*.log
.DS_Store
EOF

cat > .eslintrc.json <<'EOF'
{
  "extends": ["next/core-web-vitals", "prettier"],
  "rules": {
    "no-console": "warn",
    "react/no-unescaped-entities": "off"
  }
}
EOF

cat > .prettierrc <<'EOF'
{
  "semi": true,
  "singleQuote": true,
  "tabWidth": 2,
  "printWidth": 100,
  "trailingComma": "all"
}
EOF

cat > package.json <<'EOF'
{
  "name": "awesome-app",
  "version": "0.4.2",
  "type": "module",
  "scripts": {
    "dev": "next dev --turbo",
    "build": "next build",
    "start": "next start",
    "test": "vitest",
    "lint": "eslint ."
  },
  "dependencies": {
    "next": "^15.0.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0"
  },
  "devDependencies": {
    "@types/node": "^22.0.0",
    "@types/react": "^19.0.0",
    "eslint": "^9.0.0",
    "typescript": "^5.6.0",
    "vitest": "^2.1.0"
  }
}
EOF

cat > composer.json <<'EOF'
{
  "name": "example/awesome-app-api",
  "description": "Companion PHP API for awesome-app",
  "require": {
    "php": "^8.4",
    "laravel/framework": "^12.0",
    "predis/predis": "^2.2"
  },
  "require-dev": {
    "pestphp/pest": "^3.0",
    "laravel/pint": "^1.18"
  }
}
EOF

cat > docker-compose.yml <<'EOF'
services:
  app:
    build: .
    ports: ["3000:3000"]
    depends_on: [postgres, redis]
    volumes:
      - ./src:/app/src

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: awesome_dev
      POSTGRES_USER: dev
      POSTGRES_PASSWORD: dev
    volumes:
      - pg-data:/var/lib/postgresql/data
    ports: ["5432:5432"]

  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]

volumes:
  pg-data:
EOF

cat > Dockerfile <<'EOF'
FROM node:20-alpine AS base
WORKDIR /app
COPY package*.json ./
RUN npm ci

FROM base AS builder
COPY . .
RUN npm run build

FROM base AS runner
ENV NODE_ENV=production
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/public ./public
EXPOSE 3000
CMD ["npm", "start"]
EOF

# ─── .github/ ────────────────────────────────────────────────────────
cat > .github/workflows/ci.yml <<'EOF'
name: CI
on: [push, pull_request]
jobs:
  lint-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: npm ci
      - run: npm run lint
      - run: npm test
EOF

cat > .github/workflows/release.yml <<'EOF'
name: Release
on:
  push:
    tags: ['v*']
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: softprops/action-gh-release@v2
EOF

cat > .github/workflows/codeql.yml <<'EOF'
name: CodeQL
on:
  schedule:
    - cron: '0 6 * * 1'
jobs:
  analyze:
    runs-on: ubuntu-latest
    permissions:
      security-events: write
    steps:
      - uses: actions/checkout@v4
      - uses: github/codeql-action/init@v3
      - uses: github/codeql-action/analyze@v3
EOF

cat > .github/ISSUE_TEMPLATE/bug_report.md <<'EOF'
---
name: Bug report
about: Something is not working
---

## What happened
## Expected behaviour
## Steps to reproduce
EOF

# ─── src/ ────────────────────────────────────────────────────────────
cat > src/main.js <<'EOF'
// Entry point — wires React + fetches the initial user
import { render } from 'react-dom';
import App from './components/App';

render(<App />, document.getElementById('root'));
EOF

cat > src/index.ts <<'EOF'
export { Button } from './components/Button';
export { Modal } from './components/Modal';
export { Input } from './components/Input';
export { Card } from './components/Card';
export { Select } from './components/Select';

export { useAuth } from './hooks/useAuth';
export { useToast } from './hooks/useToast';
export { useDebounce } from './hooks/useDebounce';
EOF

for comp in Button Modal Input Card Select; do
    cat > "src/components/${comp}.tsx" <<EOF
import { type FC, type ReactNode } from 'react';

interface ${comp}Props {
    label?: string;
    children?: ReactNode;
    onClick?: () => void;
}

export const ${comp}: FC<${comp}Props> = ({ label, children, onClick }) => (
    <div className="${comp,,}" onClick={onClick}>
        {label ?? children}
    </div>
);
EOF
done

cat > src/components/index.ts <<'EOF'
export * from './Button';
export * from './Modal';
export * from './Input';
export * from './Card';
export * from './Select';
EOF

cat > src/hooks/useAuth.ts <<'EOF'
import { useState, useEffect } from 'react';

export function useAuth() {
    const [user, setUser] = useState<User | null>(null);
    useEffect(() => { /* load from token */ }, []);
    return { user, login, logout };
}
EOF

cat > src/hooks/useToast.ts <<'EOF'
import { createContext, useContext } from 'react';

const ToastContext = createContext<{ push: (msg: string) => void } | null>(null);
export const useToast = () => useContext(ToastContext);
EOF

cat > src/hooks/useDebounce.ts <<'EOF'
import { useEffect, useState } from 'react';

export function useDebounce<T>(value: T, ms = 300) {
    const [debounced, setDebounced] = useState(value);
    useEffect(() => {
        const t = setTimeout(() => setDebounced(value), ms);
        return () => clearTimeout(t);
    }, [value, ms]);
    return debounced;
}
EOF

cat > src/utils/format.ts <<'EOF'
export const slugify = (s: string) => s.toLowerCase().replace(/\s+/g, '-');
export const truncate = (s: string, n = 40) => (s.length > n ? s.slice(0, n) + '…' : s);
export const currency = (n: number, locale = 'pt-BR') =>
    new Intl.NumberFormat(locale, { style: 'currency', currency: 'BRL' }).format(n);
EOF

cat > src/utils/validate.ts <<'EOF'
export const isEmail = (s: string) => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s);
export const isUrl = (s: string) => { try { new URL(s); return true; } catch { return false; } };
EOF

cat > src/utils/api.ts <<'EOF'
export const api = {
    get: (path: string) => fetch(path).then(r => r.json()),
    post: (path: string, body: unknown) =>
        fetch(path, { method: 'POST', body: JSON.stringify(body) }).then(r => r.json()),
};
EOF

cat > src/types/index.d.ts <<'EOF'
export interface User {
    id: string;
    email: string;
    name: string;
    role: 'admin' | 'member' | 'guest';
}

export interface ApiError {
    code: string;
    message: string;
    details?: Record<string, unknown>;
}
EOF

# ─── tests/ ──────────────────────────────────────────────────────────
cat > tests/main.test.js <<'EOF'
import { describe, test, expect } from 'vitest';
describe('main', () => {
    test('boots', () => { expect(true).toBe(true); });
});
EOF

for comp in Button Modal; do
    cat > "tests/components/${comp}.test.tsx" <<EOF
import { describe, test, expect } from 'vitest';
import { render } from '@testing-library/react';
import { ${comp} } from '../../src/components/${comp}';

describe('${comp}', () => {
    test('renders label', () => {
        const { container } = render(<${comp} label="hello" />);
        expect(container.textContent).toContain('hello');
    });
});
EOF
done

cat > tests/utils/format.test.ts <<'EOF'
import { describe, test, expect } from 'vitest';
import { slugify, truncate } from '../../src/utils/format';

describe('format', () => {
    test('slugify', () => { expect(slugify('Hello World')).toBe('hello-world'); });
    test('truncate', () => { expect(truncate('abcdef', 4)).toBe('abcd…'); });
});
EOF

# ─── docs/ ───────────────────────────────────────────────────────────
cat > docs/architecture.md <<'EOF'
# Architecture

## Layers

1. **Frontend** (Next.js 15 + React 19) — SSR + RSC
2. **API** (Laravel 12) — REST + queued jobs (Redis)
3. **Data** — PostgreSQL 16 (OLTP) + Redis (cache/queue)
4. **Infra** — Docker Compose (dev) → Kubernetes (prod)

## Boundaries

The frontend talks to the API over HTTP only. No shared types beyond
what `packages/shared` exports; each side has its own build pipeline.
EOF

cat > docs/setup.md <<'EOF'
# Setup

## Prerequisites

- Node 20 LTS (check with `node --version`)
- Docker + Docker Compose
- pnpm 9+ (`npm i -g pnpm` if missing)

## First run

```bash
pnpm install
cp .env.example .env
docker compose up -d postgres redis
pnpm dev
```

Visit http://localhost:3000.
EOF

cat > docs/api.md <<'EOF'
# API

Base URL: `http://localhost:8000/api/v1`

## Auth

All routes under `/api/v1/*` require a bearer token:

```
Authorization: Bearer <token>
```

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/users/me` | current user profile |
| `GET` | `/users/:id` | public profile |
| `POST` | `/sessions` | login (returns token) |
| `DELETE` | `/sessions` | logout |
EOF

cat > docs/contributing.md <<'EOF'
# Contributing

Fork, branch, PR — standard flow. Run `pnpm lint && pnpm test` before
pushing. Commit messages follow Conventional Commits.
EOF

cat > docs/images/diagram.svg <<'EOF'
<?xml version="1.0"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 80">
  <rect x="10" y="10" width="80" height="60" fill="#89b4fa" rx="4"/>
  <rect x="110" y="10" width="80" height="60" fill="#a6e3a1" rx="4"/>
  <text x="50" y="45" text-anchor="middle" font-size="12">Frontend</text>
  <text x="150" y="45" text-anchor="middle" font-size="12">API</text>
</svg>
EOF

# ─── public/ ─────────────────────────────────────────────────────────
cat > public/index.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <title>awesome-app</title>
</head>
<body>
    <div id="root"></div>
    <script type="module" src="/src/main.js"></script>
</body>
</html>
EOF

# 10-byte placeholder favicon (still valid PNG signature)
printf '\x89PNG\r\n\x1a\n' > public/favicon.ico

# ─── scripts/ ────────────────────────────────────────────────────────
for s in build deploy test; do
    cat > "scripts/${s}.sh" <<EOF
#!/usr/bin/env bash
# scripts/${s}.sh — project ${s} orchestration
set -euo pipefail
echo "running ${s}…"
EOF
    chmod +x "scripts/${s}.sh"
done

# ─── Commit history — makes vcs segment show a real branch ───────────
git add -A
git commit --quiet -m "initial full-stack scaffold"

cat > docs/api.md <<'EOF'
# API

Updated with auth flow. See /docs/auth.md for JWT details.
EOF
git add docs/api.md
git commit --quiet -m "docs(api): clarify auth section"

echo "const VERSION = '0.4.2';" >> src/main.js
git add src/main.js
git commit --quiet -m "chore: bump version to 0.4.2"

# Branch off main to a feature branch — p10k shows the branch name in VCS
git checkout --quiet -b feat/new-button-variants

cat > src/components/Button.tsx <<'EOF'
import { type FC, type ReactNode } from 'react';

interface ButtonProps {
    label?: string;
    children?: ReactNode;
    onClick?: () => void;
    variant?: 'primary' | 'secondary' | 'danger';   // NEW
    size?: 'sm' | 'md' | 'lg';                       // NEW
}

export const Button: FC<ButtonProps> = ({
    label, children, onClick,
    variant = 'primary', size = 'md',
}) => (
    <button
        type="button"
        onClick={onClick}
        className={`btn btn-${variant} btn-${size}`}
    >
        {label ?? children}
    </button>
);
EOF
git add src/components/Button.tsx
git commit --quiet -m "feat(Button): variant + size props"

# ─── GitHub remote (triggers p10k's GitHub icon in the vcs segment) ──
# p10k inspects the remote URL string — the repo doesn't have to exist
# on GitHub, it just needs to look like a github.com remote.
git remote add origin https://github.com/example/awesome-app.git

# ─── Leave the repo dirty in 3 interesting ways ──────────────────────
#   1. Unstaged change (modify a tracked file)
cat >> src/components/Button.tsx <<'EOF'

// TODO: add icon slot
EOF

#   2. Staged change (new file, then git add it)
cat > src/components/Toast.tsx <<'EOF'
import { type FC } from 'react';

interface ToastProps {
    message: string;
    tone?: 'success' | 'warning' | 'error';
}

export const Toast: FC<ToastProps> = ({ message, tone = 'success' }) => (
    <div className={`toast toast-${tone}`}>{message}</div>
);
EOF
git add src/components/Toast.tsx

#   3. Untracked — sprinkle a new file without git add
cat > src/components/ToastStack.tsx <<'EOF'
// WIP: renders multiple toasts in a stack
EOF

echo
echo "✓ rich demo repo ready at $DEMO_DIR"
echo "  branch:  $(git branch --show-current)"
echo "  remote:  $(git remote get-url origin)    ← triggers GitHub icon"
echo "  commits: $(git rev-list --count HEAD)"
echo "  dirty:   1 staged, 1 unstaged, 1 untracked"
echo
echo "Capture checklist:"
echo "  cd $DEMO_DIR"
echo "  clear && ls                    # the prompt is now showing:"
echo "                                 #   os_icon · dir · GH-branch · dirty markers"
echo "                                 #   (direnv/asdf/node/python if those tools are installed)"
echo "  cd src/components              # nested path → truncated/dotted dir segment"
echo "  ls                             # shows Button/Modal/… Toast.tsx (untracked, highlighted)"
echo "  sleep 2                        # next prompt shows command_execution_time"
echo "  (press TAB on: 'bat src/c<TAB>' to capture fzf-tab preview pane)"
echo
echo "Save the result as: ~/dotfiles-template/assets/previews/p10k-bundled.png"
