#! /usr/bin/env -S deno run -A

import * as path from "jsr:@std/path@1.1.2";
import { walk } from "jsr:@std/fs@1.0.19";

const STASH_TEST_MODE = Deno.env.get("STASH_TEST_MODE") === "1";

function debugLog(...args: unknown[]) {
  if (!STASH_TEST_MODE) return;
  console.debug(...args);
}

// Parse command line arguments
// const VERIFY_MODE = Deno.args.includes("--verify");
const activationPackageArg = Deno.args.find((arg) => !arg.startsWith("--"));

if (!activationPackageArg) {
  throw new Error("usage: activate.ts [--verify] [activation package]");
}

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
    const stat = await Deno.lstat(path);
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

interface ManifestEntry {
  source: string;
  target: string;
  parent: string | null;
  static: boolean;
  forced: boolean;
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

interface GenerationMeta {
  homeDirectory: string;
  user: string;
}

const newGeneration = activationPackageArg;
const newGenData: Record<string, StashEntry> = JSON.parse(
  await Deno.readTextFile(`${newGeneration}/stash.json`),
);
const newGenMeta: GenerationMeta = JSON.parse(
  await Deno.readTextFile(`${newGeneration}/meta.json`),
);

const HOME = newGenMeta.homeDirectory;
const USER = newGenMeta.user;
const homeEnv = Deno.env.get("HOME") ?? "<no value>";
const userEnv = Deno.env.get("USER") ?? "<no value>";

if (HOME !== homeEnv) {
  throw new Error(
    `HOME is set to ${homeEnv} but expected value is ${HOME}`,
  );
}

if (USER !== userEnv) {
  throw new Error(
    `USER is set to ${userEnv} but expected value is ${USER}`,
  );
}

const userStatePath = Deno.env.get("XDG_STATE_HOME") ||
  path.join(HOME, ".local/state");
const statePath = path.join(userStatePath, "stash");
const gcRootsPath = path.join(statePath, "gcroots");
const newGenPath = path.join(gcRootsPath, "new-home");
const oldGenPath = path.join(gcRootsPath, "current-home");

const oldGenDataPath = path.join(oldGenPath, "stash.json");

const oldManifestPath = path.join(statePath, "manifest.json");
const newManifestPath = path.join(statePath, "new-manifest.json");

const oldManifest = await getFileOrNull(
  oldManifestPath,
  async (_) => {
    const data = await Deno.readTextFile(oldManifestPath);
    return JSON.parse(data) as Record<string, ManifestEntry>;
  },
);

const oldGenData = await getFileOrNull(
  oldGenDataPath,
  async (_) => {
    const data = await Deno.readTextFile(oldGenDataPath);
    return JSON.parse(data) as Record<string, StashEntry>;
  },
);

const partialOldGen = (oldManifest === null) !== (oldGenData === null);
if (partialOldGen) {
  console.warn(
    `WARNING: previous generation is missing key data. ${
      oldManifest === null ? "manifest" : "configuration"
    } is missing!`,
  );
}

debugLog(
  `[toplevel] old manifest:`,
  oldManifest,
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
        details:
          "This can happen during rollbacks when source files from previous generations are no longer available",
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
        details:
          "This can happen during rollbacks when file types change between generations",
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
  debugLog("[collision] checking", file);
  const targetStat = await getFileOrNull(fullTargetPath);

  if (targetStat === null) {
    debugLog(
      `[collision] target does not exist, no collision: ${fullTargetPath}`,
    );
    return CollisionType.Nothing;
  }

  // If file is marked as forced, ignore collision check and overwrite
  if (file.forced) {
    debugLog(
      `[collision] forced overwrite, ignoring existing target: ${fullTargetPath}`,
    );
    return CollisionType.Forced;
  }

  const resolvedPath = await Deno.realPath(fullTargetPath).catch((err) => null);
  if (oldManifest !== null && oldGenData !== null) {
    // check if target path was managed by previous generation
    if (
      (file.parent && oldGenData[file.parent]) ||
      oldManifest[file.target] !== undefined
    ) {
      // it was, it's safe to overwrite as a managed symlink
      debugLog(
        `[collision] managed symlink from previous manifest, safe to overwrite: ${fullTargetPath}`,
      );
      return CollisionType.ManagedSymlink;
    }

    const oldSources = new Set(Object.values(oldManifest).map((f) => f.source));
    if (resolvedPath !== null && oldSources.has(resolvedPath)) {
      // points to a source from the previous generation, but isn't in the manifest
      // at this target. This is considered a corrupted/relocated managed symlink
      // that still belongs to the old generation.
      debugLog(
        `[collision] corrupted managed symlink (points to known source but not in manifest): ${fullTargetPath}`,
      );
      return CollisionType.CorruptedManagedSymlink;
    }
  }

  // At this point, the target is not associated with any known old manifest entry.
  // Check if the target already points to the correct source before treating symlinks as fatal.
  if (resolvedPath === file.source) {
    // file from new generation (script was interrupted), or manually symlinked correctly
    debugLog(
      `[collision] identical files/symlink already points to source, skipping: ${fullTargetPath}`,
    );
    return CollisionType.IdenticalFiles;
  }

  // Target location exists. If it's already a symlink at the filesystem level
  // and we are not in a known managed state, treat it as a fatal collision.
  if (targetStat.isSymlink) {
    // If the target is already the same as the new generation source, we would
    // have already returned IdenticalFiles above.
    // At this point an unmanaged symlink is considered fatal.
    debugLog(
      `[collision] existing filesystem symlink at target, treating as fatal: ${fullTargetPath}`,
    );
    return CollisionType.SymlinkAtTarget;
  }

  const { code } = await (new Deno.Command("cmp", {
    args: [
      "-s",
      file.source,
      resolvedPath,
    ],
  })).output();

  debugLog(
    `[collision] cmp result for ${file.source} -> ${fullTargetPath} (resolved: ${resolvedPath}): exit code ${code}, isSymlink=${targetStat.isSymlink}`,
  );

  // files identical - collision, but it shouldn't be overwritten either
  if (code === 0) {
    debugLog(
      `[collision] identical files at target, will treat as IdenticalFiles: ${fullTargetPath}`,
    );
    return CollisionType.IdenticalFiles;
  } // Files are different
  // only mark for backup if target isn't a symlink
  else if (code === 1) {
    const result = targetStat.isSymlink
      ? CollisionType.SymlinkAtTarget
      : CollisionType.FileAtTarget;

    debugLog(
      `[collision] files differ, target is ${
        targetStat.isSymlink ? "symlink (fatal)" : "regular file (backup)"
      }: ${fullTargetPath}; collision=${result}`,
    );

    return result;
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

async function cleanup(
  oldEntry: ManifestEntry,
  newManifest: Record<string, ManifestEntry>,
) {
  if (
    newManifest[oldEntry.target] !== undefined
  ) {
    console.debug(`${oldEntry.target} in new generation, skipping`);
    return;
  }

  const fullTargetPath = path.join(HOME, oldEntry.target);
  const realPath = await Deno.realPath(fullTargetPath).catch(() => null);
  if (realPath !== oldEntry.source) {
    console.warn(
      `${realPath} points to unexpected location [expected ${oldEntry.source}], skipping`,
    );
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

  debugLog(
    `[validate] starting collision validation for ${
      Object.keys(newGenData).length
    } top-level entries`,
  );

  const recursedFiles = await Promise.all(
    Object.values(newGenData).map((entry) => expandEntry(entry, warnings)),
  );
  const allFiles = recursedFiles.flat();

  debugLog(
    `[validate] expanded to ${allFiles.length} manifest entries for collision checking`,
  );

  const checkedFiles = await Promise.all(allFiles.map(async (entry) => {
    const collision = await isCollision(entry);
    debugLog(
      `[validate] checked ${
        path.join(HOME, entry.target)
      }: collision=${collision}`,
    );
    return {
      entry,
      collision,
    };
  }));

  // Collect errors from fatal collisions
  for (const { entry, collision } of checkedFiles) {
    if (collision & CollisionType.Fatal) {
      const fullTargetPath = path.join(HOME, entry.target);

      debugLog(
        `[validate] fatal collision detected at ${fullTargetPath} (collision=${collision})`,
      );

      errors.push({
        type: "error",
        category: "fatal_collision",
        message:
          `Unmanaged symlink at target location cannot be safely overwritten`,
        entry,
        targetPath: fullTargetPath,
        details:
          "The target location contains a symlink that is not managed by stash. Remove it manually or use the 'forced' option.",
      });
    }
  }

  debugLog(
    `[validate] validation completed: ${errors.length} error(s), ${warnings.length} warning(s)`,
  );

  return { errors, warnings, checkedFiles };
}

async function activate() {
  debugLog("[activate] starting activation");
  const { errors, warnings, checkedFiles } = await validateCollisions();

  debugLog(
    `[activate] collision validation done, result:`,
    checkedFiles,
  );

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

    debugLog(
      `[activate] fatal validation errors (test mode): ${
        JSON.stringify(
          errors.map((e) => ({
            category: e.category,
            targetPath: e.targetPath,
            message: e.message,
          })),
          null,
          2,
        )
      }`,
    );

    throw new Error(`Fatal collisions found`);
  }

  debugLog(
    `[activate] no fatal collisions, linking ${checkedFiles.length} entries`,
  );

  const newManifestData = checkedFiles.reduce(
    (manifest, { entry }) => {
      manifest[entry.target] = entry;
      return manifest;
    },
    {} as Record<string, ManifestEntry>,
  );

  // Clean up old generation
  if (oldManifest) {
    debugLog(
      `[activate] cleaning up ${
        Object.keys(oldManifest).length
      } old manifest entries`,
    );
    await Promise.all(
      Object.values(oldManifest).map((oldEntry) =>
        cleanup(oldEntry, newManifestData)
      ),
    );
  }

  for (const entry of checkedFiles) {
    await linkFile(entry);
  }

  await Deno.writeTextFile(
    newManifestPath,
    JSON.stringify(newManifestData, null, 4),
  );
  await Deno.rename(newManifestPath, oldManifestPath);

  debugLog("[activate] activation complete");
}

async function makeGcRoot(derivation: string, rootPath: string) {
  // In test mode the script is run inside the Nix sandbox
  // without recursive-nix it doesn't have access to the Nix daemon
  // It's not really too impactful, all we need is to symlink the derivation
  // manually to the exepcted paths.
  if (STASH_TEST_MODE) {
    await Deno.mkdir(path.dirname(rootPath), { recursive: true });
    try {
      await Deno.remove(rootPath);
    } catch (e) {
      if (!(e instanceof Deno.errors.NotFound)) {
        throw e;
      }
    }
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

async function main() {
  try {
    debugLog(
      "[main] newGenData:",
      newGenData,
    );
    await makeGcRoot(newGeneration, newGenPath);
    await activate();
    await makeGcRoot(newGeneration, oldGenPath);
  } catch (error) {
    // @ts-ignore error always has message
    console.error(`Error during activation: ${error.message}`);
    if (STASH_TEST_MODE && error instanceof Error) {
      console.error(error.stack);
    }
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
