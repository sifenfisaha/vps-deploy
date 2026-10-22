#!/usr/bin/env node
/**
 * Assembles a self-sufficient Node deploy bundle from a build that has already
 * run. The output directory runs on the server with only `node` present — no
 * install step there.
 *
 *   node scripts/build-node-bundle.mjs
 *
 * Configuration, all optional:
 *
 *   BUNDLE_SRC=dist                  built JS to ship
 *   BUNDLE_OUT=deploy-bundle         output directory (inside the project)
 *   BUNDLE_LOCK=deploy-bundle-lock.json
 *                                    lockfile for the bundle's full tree; commit it
 *   BUNDLE_EXTRA=a:b,c:d             extra dirs to copy, as src:dest pairs
 *   BUNDLE_EXTRA_DEPS=pg             deps no scan can find (see below)
 *   BUNDLE_START=index.js            entry, for the generated start script
 *
 * The dependency list is derived from the bare imports in the built output
 * rather than maintained by hand, because a bundler's decision about what to
 * inline changes as its config does, and a hand-kept list drifts silently.
 *
 * The lockfile pins everything *below* those dependencies. Without it, each
 * run would resolve the transitive tree afresh from the registry, and
 * production would get a tree nobody tested.
 */

import { execFileSync } from "node:child_process";
import {
	cpSync,
	existsSync,
	mkdirSync,
	readdirSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import { builtinModules, createRequire } from "node:module";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const ROOT = process.cwd();
const SRC = resolve(ROOT, process.env.BUNDLE_SRC ?? "dist");
const OUT = resolve(ROOT, process.env.BUNDLE_OUT ?? "deploy-bundle");
const LOCK = resolve(ROOT, process.env.BUNDLE_LOCK ?? "deploy-bundle-lock.json");
const START = process.env.BUNDLE_START ?? "index.js";

/**
 * Dependencies nothing in the output names, because an *external* dependency
 * requires them at load time. `drizzle-orm` importing `pg` is the canonical
 * case: `pg` is an optional peer, so npm will not install it either, and the
 * app dies at boot with ERR_MODULE_NOT_FOUND after a clean build.
 */
const EXTRA_DEPS = (process.env.BUNDLE_EXTRA_DEPS ?? "")
	.split(",")
	.map((s) => s.trim())
	.filter(Boolean);

/** `src:dest` pairs — SQL migrations, templates, anything read at run time. */
const EXTRA_DIRS = (process.env.BUNDLE_EXTRA ?? "")
	.split(",")
	.map((s) => s.trim())
	.filter(Boolean)
	.map((pair) => {
		const [from, to] = pair.split(":");
		return { from, to: to ?? from };
	});

const die = (msg) => {
	console.error(`\n!! ${msg}\n`);
	process.exit(1);
};

/** True when `child` is `parent` or lives somewhere under it. */
function within(child, parent) {
	const rel = relative(parent, child);
	return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

if (!existsSync(SRC)) {
	die(`${SRC} does not exist — run your build first.`);
}

// OUT is wiped below. Refuse anything that would take the project, the build
// output, or a parent directory with it: BUNDLE_OUT=.. must not be a disaster.
if (!within(OUT, ROOT) || OUT === ROOT) {
	die(`BUNDLE_OUT must be a directory inside the project, got ${OUT}`);
}
if (within(SRC, OUT) || within(OUT, SRC)) {
	die(`BUNDLE_OUT (${OUT}) and BUNDLE_SRC (${SRC}) must not contain each other`);
}

function readJson(path) {
	return JSON.parse(readFileSync(path, "utf8"));
}

/** `pkg/sub` -> `pkg`, `@scope/pkg/sub` -> `@scope/pkg`. */
function packageNameOf(specifier) {
	const parts = specifier.split("/");
	return specifier.startsWith("@") ? parts.slice(0, 2).join("/") : parts[0];
}

function isBare(specifier) {
	return (
		specifier.length > 0 &&
		!specifier.startsWith(".") &&
		!specifier.startsWith("/") &&
		!specifier.startsWith("node:") &&
		!specifier.startsWith("#")
	);
}

function scan(dir, found = new Set()) {
	// `from "x"`, `import "x"`, `import("x")`, `require("x")`. The bare
	// side-effect form matters: `import "dotenv/config"` has no `from`.
	const pattern =
		/(?:\bfrom\s*|\bimport\s*\(\s*|\brequire\s*\(\s*|\bimport\s+)["']([^"']+)["']/g;

	for (const entry of readdirSync(dir, { withFileTypes: true })) {
		const path = join(dir, entry.name);

		if (entry.isDirectory()) {
			scan(path, found);
		} else if (/\.(m|c)?js$/.test(entry.name)) {
			for (const [, specifier] of readFileSync(path, "utf8").matchAll(pattern)) {
				if (isBare(specifier)) {
					found.add(packageNameOf(specifier));
				}
			}
		}
	}

	return found;
}

/**
 * Only packages something in the workspace actually depends on. Scanning alone
 * is too eager — a user-facing string like `from "the library"` in an error
 * message reads exactly like an import.
 */
function declaredDependencies() {
	const manifests = [join(ROOT, "package.json")];

	for (const group of ["apps", "packages", "services", "libs"]) {
		const dir = join(ROOT, group);

		if (existsSync(dir)) {
			for (const name of readdirSync(dir)) {
				manifests.push(join(dir, name, "package.json"));
			}
		}
	}

	const declared = new Set();

	for (const manifest of manifests) {
		if (!existsSync(manifest)) {
			continue;
		}

		const parsed = readJson(manifest);

		for (const [name, version] of Object.entries(parsed.dependencies ?? {})) {
			// Workspace-internal packages are bundled, not installed.
			if (!String(version).startsWith("workspace:")) {
				declared.add(name);
			}
		}
	}

	return { declared, manifests: manifests.filter((m) => existsSync(m)) };
}

const { declared, manifests } = declaredDependencies();

/**
 * The nearest package.json above the built output decides whether Node reads
 * its `.js` files as ES modules or CommonJS — the same rule Node applies — so
 * the bundle's manifest must say the same thing or the entry dies at boot.
 */
function nearestManifest(from) {
	let dir = from;

	while (true) {
		const candidate = join(dir, "package.json");

		if (existsSync(candidate)) {
			return readJson(candidate);
		}

		const parent = dirname(dir);

		if (parent === dir || !within(parent, ROOT)) {
			return {};
		}

		dir = parent;
	}
}

const srcManifest = nearestManifest(SRC);
const rootManifest = existsSync(join(ROOT, "package.json")) ? readJson(join(ROOT, "package.json")) : {};

/**
 * pnpm links strictly: a package resolves only from the workspace member that
 * declares it. One require context is not enough in a monorepo.
 */
const resolvers = manifests.map((manifest) => createRequire(pathToFileURL(manifest)));

function versionOf(name) {
	// Read the installed manifest directly first. `require` resolution fails
	// for packages whose `exports` map hides package.json or has no `require`
	// entry — common for ESM-only packages — although they are installed fine.
	for (const manifest of manifests) {
		let dir = dirname(manifest);

		while (true) {
			const candidate = join(dir, "node_modules", name, "package.json");

			if (existsSync(candidate)) {
				try {
					return readJson(candidate).version;
				} catch {
					// fall through to the next location
				}
			}

			const parent = dirname(dir);

			if (parent === dir) {
				break;
			}

			dir = parent;
		}
	}

	for (const req of resolvers) {
		try {
			return req(`${name}/package.json`).version;
		} catch {
			let dir;

			try {
				dir = dirname(req.resolve(name));
			} catch {
				continue;
			}

			while (dir !== dirname(dir)) {
				const manifest = join(dir, "package.json");

				if (existsSync(manifest)) {
					const parsed = readJson(manifest);

					if (parsed.name === name) {
						return parsed.version;
					}
				}

				dir = dirname(dir);
			}
		}
	}

	return null;
}

const scanned = [...scan(SRC)].filter((name) => declared.has(name));
const runtime = [...new Set([...scanned, ...EXTRA_DEPS])]
	.filter((name) => !builtinModules.includes(name))
	.sort((a, b) => a.localeCompare(b));

const dependencies = {};
const unresolved = [];

for (const name of runtime) {
	const version = versionOf(name);

	if (version) {
		dependencies[name] = version;
	} else {
		unresolved.push(name);
	}
}

if (unresolved.length > 0) {
	die(
		`cannot resolve: ${unresolved.join(", ")}\n   Run your package manager's install first, or drop them from BUNDLE_EXTRA_DEPS.`
	);
}

console.log(
	`runtime dependencies (${runtime.length}): ${runtime.join(", ") || "none"}`
);

rmSync(OUT, { force: true, recursive: true });
mkdirSync(OUT, { recursive: true });

const bundleManifest = {
	name: "deploy-bundle",
	private: true,
	type: srcManifest.type ?? "commonjs",
	scripts: { start: `node ${START}` },
	dependencies,
};

// npm-style overrides carry over. pnpm's `pnpm.overrides` and patched
// dependencies do not — npm does not understand them — which is one more
// reason to start the bundle locally before shipping it.
if (rootManifest.overrides) {
	bundleManifest.overrides = rootManifest.overrides;
}

writeFileSync(
	join(OUT, "package.json"),
	`${JSON.stringify(bundleManifest, null, 2)}\n`
);

if (Object.keys(dependencies).length > 0) {
	const npm = (args) =>
		execFileSync("npm", [...args, "--omit=dev", "--no-audit", "--no-fund", "--loglevel=error"], {
			cwd: OUT,
			stdio: "inherit",
		});
	const hadLock = existsSync(LOCK);
	let installed = false;

	if (hadLock) {
		// `npm ci` refuses a lockfile that no longer matches the dependency
		// list, which is exactly when it has to be regenerated.
		cpSync(LOCK, join(OUT, "package-lock.json"));
		console.log(`installing production dependencies from ${basename(LOCK)}…`);

		try {
			npm(["ci"]);
			installed = true;
		} catch {
			console.log(`${basename(LOCK)} no longer matches the dependency list; resolving afresh…`);
			rmSync(join(OUT, "package-lock.json"), { force: true });
		}
	}

	if (!installed) {
		console.log("installing production dependencies…");
		npm(["install"]);
	}

	const written = join(OUT, "package-lock.json");

	if (existsSync(written)) {
		const fresh = readFileSync(written, "utf8");

		if (!hadLock || fresh !== readFileSync(LOCK, "utf8")) {
			writeFileSync(LOCK, fresh);
			console.log(
				`\n!! ${basename(LOCK)} was ${hadLock ? "updated" : "created"}. Commit it: it pins the bundle's full dependency tree.`
			);
		}
	} else {
		console.log("!! npm wrote no package-lock.json, so the transitive tree is not pinned between deploys");
	}
}

cpSync(SRC, OUT, { recursive: true });

for (const { from, to } of EXTRA_DIRS) {
	const source = resolve(ROOT, from);

	if (!existsSync(source)) {
		die(`BUNDLE_EXTRA refers to ${from}, which does not exist`);
	}

	cpSync(source, join(OUT, to), { recursive: true });
	console.log(`copied ${from} -> ${to}`);
}

console.log(`\nbundle ready at ${OUT}`);
console.log(
	`verify it before deploying:\n  cd ${OUT} && PORT=39999 node --env-file=../${basename(resolve(ROOT, ".env.production"))} ${START}\n  curl -fsS http://127.0.0.1:39999/`
);
