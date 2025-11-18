#! /usr/bin/env -S deno run -A

import * as path from "jsr:@std/path@1.1.2";
import { walk } from "jsr:@std/fs@1.0.19";

const STASH_TEST_MODE = Deno.env.get("STASH_TEST_MODE") === "1";

// Parse command line arguments
const VERIFY_MODE = Deno.args.includes("--verify");
const activationPackageArg = Deno.args.find(arg => !arg.startsWith("--"));

if (!activationPackageArg) {
  throw new Error("usage: activate.ts [--verify] [activation package]");
}</parameter>

async function getFileOrNull(path: string): Promise<Deno.FileInfo | null>;
async function getFileOrNull<T>(
  path: string,
  process: (data: Deno.FileInfo) => T,
): Promise<T | null>;
async function getFileOrNull<T>(
  path: string,
  process: (data: Deno.FileInfo) => T = (data: Deno.FileInfo) => data as T,
): Promise<T | Deno.FileInfo | null> {
  try {
    const stat = await Deno.stat(path);
    return await process(stat);
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      return null;
    }
    // Re-throw any other unexpected error
    throw error;
  }
}

interface StashEntry {
  source: string;
  target: string;
  recursive: boolean;
  static: boolean;
  forced?: boolean;
}

enum CollisionType {
  Nothing = 0,
  Collision = 1, // target exits already
  Overwrite = 1 << 1, // can be overwritten safely
  Backup = 1 << 2, // should be backed up beforehand (or fatal if backups are disabled)
  Skip = 1 << 3, // skip dealing with this file entirely
  Fatal = 1 << 4, // fatal error
  IdenticalFiles = Collision | Skip,
  ManagedSymlink = Collision | Overwrite,
  CorruptedManagedSymlink = Collision | Overwrite,
  FileAtTarget = Collision | Backup,
  SymlinkAtTarget = Collision | Fatal,
  Forced = Nothing | Overwrite,
}

interface ManifestEntry {
  source: string;
  target: string;
  parent: string | null;
  static: boolean;
  forced: boolean;
}

interface ValidationError {
  type: "error";
  category: "fatal_collision" | "missing_source" | "type_mismatch";
  message: string;
  entry: ManifestEntry;
  targetPath: string;
  details?: string;
}

interface ValidationWarning {
  type: "warning";
  category: "missing_source" | "corrupted_symlink" | "unexpected_type";
  message: string;
  entry?: StashEntry;
  path: string;
  details?: string;
}

interface ValidationResult {
  errors: ValidationError[];
  warnings: ValidationWarning[];
  checkedFiles: Array<{ entry: ManifestEntry; collision: CollisionType }>;
}

const newGeneration = activationPackageArg;
const newGenData: Record<string, StashEntry> = JSON.parse(
  await Deno.readTextFile(`${newGeneration}/stash.json`),
);

const HOME = Deno.env.get("HOME")!;

console.debug(`HOME: ${HOME}`);

if (!HOME) {
  throw new Error("$HOME must be set.");
}

const userStatePath = Deno.env.get("XDG_STATE_HOME") ||
  path.join(HOME, ".local/state");
const statePath = path.join(userStatePath, "stash");
const gcRootsPath = path.join(statePath, "gcroots");
const newGenPath = path.join(gcRootsPath, "new-home");
const oldGenPath = path.join(gcRootsPath, "current-home");

const oldManifestPath = path.join(statePath, "manifest.json");
const newManifestPath = path.join(statePath, "new-manifest.json");

const oldManifest = await getFileOrNull<Promise<Record<string, ManifestEntry>>>(
  oldManifestPath,
  async (_) => {
    const data = await Deno.readTextFile(oldManifestPath);
    return JSON.parse(data);
  },
);

async function expandEntry(
  entry: StashEntry,
  warnings: ValidationWarning[],
): Promise<ManifestEntry[]> {
  // static files are checked by Nix on evaluation/build
  if (!entry.static) {
    const stat = await getFileOrNull(entry.source);
    if (!stat) {
      warnings.push({
        type: "warning",
        category: "missing_source",
        message: `Source does not exist, skipping`,
        entry,
        path: entry.source,
        details: "This can happen during rollbacks when source files from previous generations are no longer available",
      });
      return [];
    }

    if (entry.recursive && !stat.isDirectory) {
      warnings.push({
        type: "warning",
        category: "unexpected_type",
        message: `Recursive mode specified but source is not a directory`,
        entry,
        path: entry.source,
        details: "This can happen during rollbacks when file types change between generations",
      });
      return [];
    }
  }

  if (!entry.recursive) {
    return [{
      source: entry.source,
      target: entry.target,
      static: entry.static,
      forced: entry.forced ?? false,
      parent: null,
    }];
  }

  const contents = await Array.fromAsync(walk(entry.source, {
    followSymlinks: false,
    includeDirs: false,
  }));

  return contents.map((f) => {
    const relative = path.relative(entry.source, f.path);
    return {
      source: f.path,
      target: path.join(entry.target, relative),
      parent: entry.target,
      forced: entry.forced ?? false,
      static: entry.static,
    };
  });
}

async function isCollision(file: ManifestEntry): Promise<CollisionType> {
  const fullTargetPath = path.join(HOME, file.target);
  const targetStat = await getFileOrNull(fullTargetPath);

  if (targetStat === null) return CollisionType.Nothing;
  // If file is marked as forced, ignore collision check and overwrite
  if (file.forced) return CollisionType.Forced;

  // Target location exists
  const resolvedPath = await Deno.realPath(fullTargetPath);
  if (resolvedPath === file.source) {
    // symlink from new generation (script was interrupted), can be skipped
    return CollisionType.IdenticalFiles;
  }

  if (oldManifest !== null) {
    // check if target path was managed by previous generation
    if (oldManifest[file.target] !== undefined) {
      // it was, it's safe to overwrite
      return CollisionType.ManagedSymlink;
    }

    const oldSources = Object.values(oldManifest).map((file) => file.source);
    if (oldSources.includes(resolvedPath)) {
      // points to previous generation, but isn't in the manifest...
      // possible manual symlink by user
      // or partial/interrupted activation
      // or symlink was moved manually
      return CollisionType.CorruptedManagedSymlink;
    }
  }

  const { code } = await (new Deno.Command("cmp", {
    args: [
      "-s",
      file.source,
      resolvedPath,
    ],
  })).output();

  // files identical - collision, but it shouldn't be overwritten either
  if (code === 0) return CollisionType.IdenticalFiles;
  // Files are different
  // only mark for backup if target isn't a symlink
  else if (code === 1) {
    return targetStat.isSymlink
      ? CollisionType.SymlinkAtTarget
      : CollisionType.FileAtTarget;
  } else {
    console.error(
      `error running cmp -s ${file.source} ${resolvedPath}: code ${code}`,
    );
    throw new Error(`cmp command failed with code ${code}`);
  }
}

async function linkFile(
  { entry, collision }: { entry: ManifestEntry; collision: CollisionType },
) {
  const fullTargetPath = path.join(HOME, entry.target);
  if (collision & CollisionType.Fatal) {
    console.error(
      `Cannot continue: file at ${fullTargetPath} would be overwritten`,
    );
  }

  if (collision === CollisionType.IdenticalFiles) {
    console.debug(
      `Skipping linking ${fullTargetPath}, identical to ${entry.source}`,
    );
    return;
  }

  // TODO: add option to disable backup overwrites
  const backupPath = `${fullTargetPath}.stash.bak`;
  if (collision & CollisionType.Backup) {
    console.debug(`making backup of ${fullTargetPath}`);
    await Deno.rename(fullTargetPath, backupPath);
  }

  await Deno.mkdir(path.dirname(fullTargetPath), { recursive: true });

  // replace link atomically
  const tmpLinkPath = `${fullTargetPath}.stash.tmp`;
  await Deno.remove(tmpLinkPath).catch(() => {});
  await Deno.symlink(entry.source, tmpLinkPath);
  await Deno.rename(tmpLinkPath, fullTargetPath);
}

async function cleanup(oldEntry: ManifestEntry) {
  if (
    newGenData[oldEntry.target] !== undefined ||
    (oldEntry.parent !== null && newGenData[oldEntry.parent] !== undefined)
  ) {
    console.debug(`${oldEntry.target} in new generation, skipping`);
    return;
  }

  const fullTargetPath = path.join(HOME, oldEntry.target);
  if (
    (await Deno.realPath(fullTargetPath).catch(() => null)) !== oldEntry.source
  ) {
    console.warn(`${fullTargetPath} points to unexpected location, skipping`);
    return;
  }

  try {
    await Deno.remove(fullTargetPath);
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) {
      throw error;
    }
    console.debug(`stale link ${fullTargetPath} already gone, skipping`);
  }

  for (
    let currentDir = path.dirname(fullTargetPath);
    currentDir !== HOME && currentDir.startsWith(HOME);
    currentDir = path.dirname(currentDir)
  ) {
    try {
      await Deno.remove(currentDir);
      console.debug(`Removed empty directory ${currentDir}`);
    } catch (error) {
      if (error instanceof Deno.errors.NotFound) {
        console.debug(
          `deleting directory ${currentDir} but not found, skipping`,
        );
        continue;
      }
      const err = error as Error;
      console.debug(
        `Could not remove directory ${currentDir}, stopping cleanup: ${err.message}`,
      );
      break;
    }
  }
}

async function validateCollisions(): Promise<ValidationResult> {
  const warnings: ValidationWarning[] = [];
  const errors: ValidationError[] = [];

  const recursedFiles = await Promise.all(
    Object.values(newGenData).map((entry) => expandEntry(entry, warnings)),
  );
  const allFiles = recursedFiles.flat();

  const checkedFiles = await Promise.all(allFiles.map(async (entry) => {
    return {
      entry,
      collision: await isCollision(entry),
    };
  }));

  // Collect errors from fatal collisions
  for (const { entry, collision } of checkedFiles) {
    if (collision & CollisionType.Fatal) {
      const fullTargetPath = path.join(HOME, entry.target);
      errors.push({
        type: "error",
        category: "fatal_collision",
        message: `Unmanaged symlink at target location cannot be safely overwritten`,
        entry,
        targetPath: fullTargetPath,
        details: "The target location contains a symlink that is not managed by stash. Remove it manually or use the 'forced' option.",
      });
    }
  }

  return { errors, warnings, checkedFiles };
}

async function activate() {
  const { errors, warnings, checkedFiles } = await validateCollisions();

  // Log warnings during activation
  for (const warning of warnings) {
    console.warn(`WARNING: ${warning.message}: ${warning.path}`);
    if (warning.details) {
      console.warn(`  ${warning.details}`);
    }
  }

  if (errors.length > 0) {
    console.error(`ERROR: ${errors.length} collision(s) found:`);
    for (const error of errors) {
      console.error(`  ${error.message}: ${error.targetPath}`);
      if (error.details) {
        console.error(`    ${error.details}`);
      }
    }
    throw new Error(`Fatal collisions found`);
  }

  // Link new generation, obtaining manifest
  const newManifestData = checkedFiles.reduce(
    (manifest, { entry }) => {
      manifest[entry.target] = entry;
      return manifest;
    },
    {} as Record<string, ManifestEntry>,
  );

  // Clean up old generation
  if (oldManifest) {
    await Promise.all(Object.values(oldManifest).map(cleanup));
  }

  for (const entry of checkedFiles) {
    await linkFile(entry);
  }

  await Deno.writeTextFile(
    newManifestPath,
    JSON.stringify(newManifestData, null, 4),
  );
  await Deno.rename(newManifestPath, oldManifestPath);
}

async function makeGcRoot(derivation: string, rootPath: string) {
  if (STASH_TEST_MODE) {
    await Deno.mkdir(path.dirname(rootPath), { recursive: true });
    await Deno.symlink(derivation, rootPath);
    return;
  }

  const command = new Deno.Command("nix-store", {
    args: [
      "--realise",
      derivation,
      "--add-root",
      rootPath,
    ],
  });
  await command.output();
}
}

async function verify() {
console.log("Running validation checks...");
const { errors, warnings } = await validateCollisions();

let hasIssues = false;

if (warnings.length > 0) {
  console.log(`\n⚠️  Found ${warnings.length} warning(s):\n`);
  for (const warning of warnings) {
    console.log(`WARNING [${warning.category}]: ${warning.message}`);
    console.log(`  Path: ${warning.path}`);
    if (warning.details) {
      console.log(`  Details: ${warning.details}`);
    }
    console.log();
  }
  hasIssues = true;
}

if (errors.length > 0) {
  console.log(`\n❌ Found ${errors.length} error(s):\n`);
  for (const error of errors) {
    console.log(`ERROR [${error.category}]: ${error.message}`);
    console.log(`  Target: ${error.targetPath}`);
    console.log(`  Source: ${error.entry.source}`);
    if (error.details) {
      console.log(`  Details: ${error.details}`);
    }
    console.log();
  }
  hasIssues = true;
}

if (!hasIssues) {
  console.log("✓ Validation passed: No errors or warnings found.");
  Deno.exit(0);
} else {
  if (errors.length > 0) {
    console.log(`\n❌ Validation failed: ${errors.length} error(s) must be resolved before activation.`);
    Deno.exit(1);
  } else {
    console.log(`\n⚠️  Validation passed with warnings: Activation can proceed but may have issues.`);
    Deno.exit(0);
  }
}
}

async function main() {
if (VERIFY_MODE) {
  await verify();
  return;
}

try {
  await makeGcRoot(newGeneration, newGenPath);
  await activate();
  await makeGcRoot(newGeneration, oldGenPath);
} catch (error) {
  // @ts-ignore error always has message
  console.error(`Error during activation: ${error.message}`);
  Deno.exit(1);
} finally {
  try {
    await Deno.remove(newGenPath);
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) {
      // @ts-ignore error
      console.warn(`Failed to remove temporary GC root: ${error.message}`);
    }
  }
}
}

if (import.meta.main) {
  await main();
}
