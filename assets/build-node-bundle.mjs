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
 *   BUNDLE_SRC=dist            built JS to ship
 *   BUNDLE_OUT=deploy-bundle   output directory
 *   BUNDLE_EXTRA=a:b,c:d       extra dirs to copy, as src:dest pairs
 *   BUNDLE_EXTRA_DEPS=pg       deps no scan can find (see below)
 *   BUNDLE_START=index.js      entry, for the generated start script
 *
 * The dependency list is derived from the bare imports in the built output
 * rather than maintained by hand, because a bundler's decision about what to
 * inline changes as its config does, and a hand-kept list drifts silently.
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
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const ROOT = process.cwd();
const SRC = resolve(ROOT, process.env.BUNDLE_SRC ?? "dist");
const OUT = resolve(ROOT, process.env.BUNDLE_OUT ?? "deploy-bundle");
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

if (!existsSync(SRC)) {
	die(`${SRC} does not exist — run your build first.`);
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

		const parsed = JSON.parse(readFileSync(manifest, "utf8"));

		for (const [name, version] of Object.entries(parsed.dependencies ?? {})) {
			// Workspace-internal packages are bundled, not installed.
			if (!String(version).startsWith("workspace:")) {
				declared.add(name);
			}
		}
	}

	return { declared, manifests };
}

const { declared, manifests } = declaredDependencies();

/**
 * pnpm links strictly: a package resolves only from the workspace member that
 * declares it. One require context is not enough in a monorepo.
 */
const resolvers = manifests
	.filter((manifest) => existsSync(manifest))
	.map((manifest) => createRequire(pathToFileURL(manifest)));

function versionOf(name) {
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
					const parsed = JSON.parse(readFileSync(manifest, "utf8"));

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

writeFileSync(
	join(OUT, "package.json"),
	`${JSON.stringify(
		{
			name: "deploy-bundle",
			private: true,
			type: "module",
			scripts: { start: `node ${START}` },
			dependencies,
		},
		null,
		2
	)}\n`
);

if (Object.keys(dependencies).length > 0) {
	console.log("installing production dependencies…");
	execFileSync(
		"npm",
		["install", "--omit=dev", "--no-audit", "--no-fund", "--loglevel=error"],
		{ cwd: OUT, stdio: "inherit" }
	);
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
	`verify it before deploying:\n  cd ${OUT} && PORT=39999 node ${START}\n  curl -fsS http://127.0.0.1:39999/`
);
