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
    // NotADirectory errors occur when trying to access a path through a non-directory
    // (e.g., checking /foo/bar/baz when /foo/bar is a file). Treat as not found.
    if (error instanceof Deno.errors.NotADirectory) {
      return null;
    }
    // Re-throw any other unexpected error
    throw error;
  }
}

type Manifest = Record<string, ManifestEntry>;

interface StashFileSource {
  static: boolean;
  stash: string | null;
  path: string;
}

interface StashFileEntry {
  target: string;
  recursive: boolean;
  forced: boolean;
  executable: boolean | null;
  source: StashFileSource;
}

interface StashGenerationConfig {
  files: Record<string, StashFileEntry>;
  stashes: Record<string, { name: string; path: string }>;
}

interface ManifestEntry {
  /**
   * Absolute path of the source file this symlink should point to.
   */
  source: string;
  /**
   * Target path relative to HOME where the symlink will be created.
   */
  target: string;
  /**
   * Top-level target path (relative to HOME) for recursive entries that
   * produced this manifest entry. Null for non-recursive entries.
   */
  recursiveRoot: string | null;
  /**
   * Whether the source comes from a static store-based tree.
   */
  static: boolean;
  /**
   * Whether this entry is allowed to overwrite existing files/symlinks.
   */
  forced: boolean;
  /**
   * Optional stash name from which this entry was sourced. Null for static
   * entries.
   */
  stash: string | null;
  /**
   * Path relative to the stash root (or static-files root) used to derive
   * this entry. This allows reconstructing higher-level intent from the
   * manifest alone.
   */
  sourceRelPath: string;
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
  category:
    | "missing_source"
    | "corrupted_symlink"
    | "unexpected_type"
    | "cleanup_mismatch";
  message: string;
  entry?: ManifestEntry;
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
const newGenConfig: StashGenerationConfig = JSON.parse(
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
    return JSON.parse(data) as Manifest;
  },
);

// Old generation configuration is currently not used in the new manifest-based
// collision logic, but we keep the path reserved for possible future use.
const oldGenConfig = await getFileOrNull(
  oldGenDataPath,
  async (_) => {
    const data = await Deno.readTextFile(oldGenDataPath);
    return JSON.parse(data) as StashGenerationConfig;
  },
);

const partialOldGen = (oldManifest === null) !== (oldGenConfig === null);
if (partialOldGen) {
  console.warn(
    `WARNING: previous generation is missing key data. ${
      oldManifest === null ? "manifest" : "configuration"
    } is missing!`,
  );
  // TODO: In the future, we may want to relax behavior when the old manifest
  // is missing or only partially available. For robustness, we could infer
  // previously managed symlinks directly from the filesystem (e.g. by scanning
  // for symlinks pointing to known stash/static sources) so that activation
  // still behaves reasonably even if manifest.json is corrupt or lost. This
  // should be covered by an explicit "corrupt/missing manifest" test case.
}

debugLog(
  `[toplevel] old manifest:`,
  oldManifest,
);

async function expandEntry(
  entry: StashFileEntry,
  stashConfig: StashGenerationConfig,
): Promise<{ entries: ManifestEntry[]; warnings: ValidationWarning[] }> {
  const targetRoot = path.join(HOME, entry.target);
  const warnings: ValidationWarning[] = [];

  // Resolve base source path: either from static-files tree or from a stash
  let baseSource: string;
  let stashName: string | null = null;
  if (entry.source.static) {
    // For static sources, the path stored in stash.json is always an absolute
    // path (see modules/default.nix: stashStateDerivation), so we can use it
    // directly without rebasing under the generation's static-files tree.
    baseSource = entry.source.path;
  } else {
    stashName = entry.source.stash;
    if (!stashName || !stashConfig.stashes[stashName]) {
      warnings.push({
        type: "warning",
        category: "missing_source",
        message: `Unknown stash '${stashName}', skipping`,
        entry,
        path: entry.source.path,
        details:
          "The stash referenced by this entry is not defined in the current generation configuration.",
      });
      return { entries: [], warnings };
    }
    const stashRoot = stashConfig.stashes[stashName].path;
    baseSource = path.join(stashRoot, entry.source.path);
  }

  const stat = await getFileOrNull(baseSource);
  if (!stat) {
    warnings.push({
      type: "warning",
      category: "missing_source",
      message: `Source does not exist, skipping`,
      entry,
      path: baseSource,
      details:
        "This can happen during rollbacks when source files from previous generations are no longer available",
    });
    return { entries: [], warnings };
  }

  if (entry.recursive && !stat.isDirectory) {
    warnings.push({
      type: "warning",
      category: "unexpected_type",
      message: `Recursive mode specified but source is not a directory`,
      entry,
      path: baseSource,
      details:
        "This can happen during rollbacks when file types change between generations",
    });
    return { entries: [], warnings };
  }

  const recursiveRoot = entry.recursive ? entry.target : null;
  const baseEntry = {
    source: baseSource,
    target: path.relative(HOME, targetRoot),
    static: entry.source.static,
    forced: entry.forced ?? false,
    recursiveRoot,
    stash: stashName,
    sourceRelPath: entry.source.path,
  };

  if (!entry.recursive) {
    return { entries: [baseEntry], warnings };
  }

  const contents = await Array.fromAsync(walk(baseSource, {
    followSymlinks: false,
    includeDirs: false,
  }));

  const entries: ManifestEntry[] = [
    baseEntry,
    ...contents.map((f) => {
      const relativePath = path.relative(baseSource, f.path);
      const targetPath = path.join(targetRoot, relativePath);
      const targetRelToHome = path.relative(HOME, targetPath);
      const relInsideSourceTree = path.join(entry.source.path, relativePath);
      return {
        source: f.path,
        target: targetRelToHome,
        recursiveRoot,
        forced: entry.forced ?? false,
        static: entry.source.static,
        stash: stashName,
        sourceRelPath: relInsideSourceTree,
      };
    }),
  ];

  return { entries, warnings };
}

type PlannedAction =
  & { priority: number }
  & (
    | {
      kind: "link";
      entry: ManifestEntry;
      backup: boolean;
    }
    | {
      kind: "remove";
      target: string;
      removeParents: boolean;
    }
  );

type ActivationPlan = {
  actions: PlannedAction[];
  warnings: ValidationWarning[];
  errors: ValidationError[];
};

type PlanStep =
  | { type: "action"; action: PlannedAction }
  | { type: "warning"; warning: ValidationWarning }
  | { type: "error"; error: ValidationError };

/**
 * Plan transition for a recursive root directory entry.
 * Roots are never created as symlinks - they must be directories on disk.
 */
async function planRootTransition(
  target: string,
  fullTargetPath: string,
  oldEntry: ManifestEntry | null,
  newEntry: ManifestEntry | null,
  fs: Deno.FileInfo | null,
): Promise<PlanStep[]> {
  const steps: PlanStep[] = [];

  const inOld = oldEntry !== null;
  const inNew = newEntry !== null;

  // Case 1: Cleanup only (root only in old generation)
  if (inOld && !inNew) {
    const entry = oldEntry!;
    if (!fs) {
      // Target already gone on disk.
      return steps;
    }

    // Root non-symlink directory: we intentionally leave it alone.
    if (!fs.isSymlink && fs.isDirectory) {
      return steps;
    }

    if (!fs.isSymlink) {
      // Previously managed but now a real file/dir (unexpected root type) → warn, do not touch.
      steps.push({
        type: "warning",
        warning: {
          type: "warning",
          category: "cleanup_mismatch",
          message:
            `Path '${fullTargetPath}' was previously managed but is now a non-symlink; leaving it untouched.`,
          entry,
          path: fullTargetPath,
          details:
            "The file has likely been modified or replaced by the user or another tool.",
        },
      });
      return steps;
    }

    const realPath = await Deno.realPath(fullTargetPath).catch(() => null);
    if (realPath === null) {
      // Previously managed symlink that now dangles → safe to remove.
      steps.push({
        type: "action",
        action: {
          kind: "remove",
          target,
          removeParents: true,
          priority: 10, // cleanup before any linking
        },
      });
      return steps;
    }

    if (realPath !== entry.source) {
      // Symlink but not pointing where we expect; treat as user-modified and leave it alone.
      steps.push({
        type: "warning",
        warning: {
          type: "warning",
          category: "cleanup_mismatch",
          message:
            `Path '${fullTargetPath}' was previously managed but now points to a different source; leaving it untouched.`,
          entry,
          path: fullTargetPath,
          details:
            `Expected to point to '${entry.source}', but now points to '${
              realPath ?? "unknown"
            }'.`,
        },
      });
      return steps;
    }

    // Exactly our old symlink → remove it.
    steps.push({
      type: "action",
      action: {
        kind: "remove",
        target,
        removeParents: true,
        priority: 10, // cleanup before any linking
      },
    });
    return steps;
  }

  // Case 2: New root (start managing a root that old did not own)
  if (!inOld && inNew) {
    const entry = newEntry!;

    if (!fs) {
      // No entry at root; leaf entries will create parent directories as needed.
      return steps;
    }

    if (fs.isSymlink) {
      // For new recursive trees, any pre-existing symlink at the root is
      // considered a fatal collision, since the root must be a directory.
      steps.push({
        type: "error",
        error: {
          type: "error",
          category: "fatal_collision",
          message:
            `Recursive root '${fullTargetPath}' is a symlink on disk; this is incompatible with a recursive tree.`,
          entry,
          targetPath: fullTargetPath,
          details:
            "Remove or relocate the existing symlink at the recursive root, or choose a different target for the recursive tree.",
        },
      });
      return steps;
    }

    if (!fs.isDirectory) {
      // Non-directory file at the root of a recursive tree is also a fatal collision.
      steps.push({
        type: "error",
        error: {
          type: "error",
          category: "type_mismatch",
          message:
            `Recursive root '${fullTargetPath}' is not a directory on disk; cannot populate recursive tree under it.`,
          entry,
          targetPath: fullTargetPath,
          details:
            "Expected a directory or nothing at the recursive root, but found a regular file or other non-directory. Remove or relocate it, or choose a different target.",
        },
      });
      return steps;
    }

    // Root is a directory → fine; leaves will populate it.
    return steps;
  }

  // Case 3: Managed root transition (root in both old and new)
  if (inOld && inNew) {
    const oldE = oldEntry!;
    const entry = newEntry!;

    if (!fs) {
      // No entry at root; leaf entries will mkdir their parents as needed.
      return steps;
    }

    if (fs.isSymlink) {
      const realPath = await Deno.realPath(fullTargetPath).catch(() => null);

      if (realPath === oldE.source) {
        // Previously managed root symlink: safe to remove so we can treat
        // the root as a directory for the new recursive tree.
        steps.push({
          type: "action",
          action: {
            kind: "remove",
            target,
            removeParents: false,
            priority: 10,
          },
        });
        return steps;
      }

      // Root symlink that does not match the old manifest's source is an
      // unmanaged collision and must be treated as fatal for recursive trees.
      steps.push({
        type: "error",
        error: {
          type: "error",
          category: "fatal_collision",
          message:
            `Recursive root '${fullTargetPath}' is a symlink on disk that does not match the previous generation; this is incompatible with a recursive tree.`,
          entry,
          targetPath: fullTargetPath,
          details:
            "The previous generation did not own this root symlink (or it was modified), and recursive roots must be directories. Remove or relocate the symlink, or choose a different target.",
        },
      });
      return steps;
    }

    if (!fs.isDirectory) {
      // Non-directory file at the root of a recursive tree is a fatal collision.
      steps.push({
        type: "error",
        error: {
          type: "error",
          category: "type_mismatch",
          message:
            `Recursive root '${fullTargetPath}' is not a directory on disk; cannot populate recursive tree under it.`,
          entry,
          targetPath: fullTargetPath,
          details:
            "Expected a directory or nothing at the recursive root, but found a regular file or other non-directory. Remove or relocate it, or choose a different target.",
        },
      });
      return steps;
    }

    // Root is a directory → leave it alone; leaves handle content.
    return steps;
  }

  return steps;
}

/**
 * Plan transition for a leaf entry (non-recursive or child of recursive tree).
 * Leaves are always created as symlinks to their sources.
 */
async function planLeafTransition(
  target: string,
  fullTargetPath: string,
  oldEntry: ManifestEntry | null,
  newEntry: ManifestEntry | null,
  fs: Deno.FileInfo | null,
): Promise<PlanStep[]> {
  const steps: PlanStep[] = [];

  const inOld = oldEntry !== null;
  const inNew = newEntry !== null;

  // Case 1: Cleanup only (leaf only in old generation)
  if (inOld && !inNew) {
    const entry = oldEntry!;
    if (!fs) {
      // Target already gone on disk.
      return steps;
    }

    if (!fs.isSymlink) {
      // Previously managed but now a real file/dir → warn, do not touch.
      steps.push({
        type: "warning",
        warning: {
          type: "warning",
          category: "cleanup_mismatch",
          message:
            `Path '${fullTargetPath}' was previously managed but is now a non-symlink; leaving it untouched.`,
          entry,
          path: fullTargetPath,
          details:
            "The file has likely been modified or replaced by the user or another tool.",
        },
      });
      return steps;
    }

    const realPath = await Deno.realPath(fullTargetPath).catch(() => null);
    if (realPath === null) {
      // Previously managed symlink that now dangles → safe to remove.
      steps.push({
        type: "action",
        action: {
          kind: "remove",
          target,
          removeParents: true,
          priority: 10,
        },
      });
      return steps;
    }

    if (realPath !== entry.source) {
      // Symlink but not pointing where we expect; treat as user-modified and leave it alone.
      steps.push({
        type: "warning",
        warning: {
          type: "warning",
          category: "cleanup_mismatch",
          message:
            `Path '${fullTargetPath}' was previously managed but now points to a different source; leaving it untouched.`,
          entry,
          path: fullTargetPath,
          details:
            `Expected to point to '${entry.source}', but now points to '${
              realPath ?? "unknown"
            }'.`,
        },
      });
      return steps;
    }

    // Exactly our old symlink → remove it.
    steps.push({
      type: "action",
      action: {
        kind: "remove",
        target,
        removeParents: true,
        priority: 10,
      },
    });
    return steps;
  }

  // Case 2: New leaf (start managing a leaf that old did not own)
  if (!inOld && inNew) {
    const entry = newEntry!;

    if (!fs) {
      // Empty target → safe to link without backup.
      steps.push({
        type: "action",
        action: {
          kind: "link",
          entry,
          backup: false,
          priority: 20,
        },
      });
      return steps;
    }

    if (!entry.forced) {
      if (fs.isSymlink) {
        // Non-forced and a symlink already exists at a leaf → fatal collision.
        steps.push({
          type: "error",
          error: {
            type: "error",
            category: "fatal_collision",
            message:
              `Target '${fullTargetPath}' already exists as a symlink and this entry is not forced.`,
            entry,
            targetPath: fullTargetPath,
            details:
              "Use 'forced = true' to allow overwriting existing symlinks, or remove the existing symlink manually.",
          },
        });
        return steps;
      }

      // Non-forced and a non-symlink exists at a leaf → backup then overwrite.
      steps.push({
        type: "action",
        action: {
          kind: "link",
          entry,
          backup: true,
          priority: 30,
        },
      });
      return steps;
    }

    // forced = true: overwrite anything that exists at a leaf, no backup.
    steps.push({
      type: "action",
      action: {
        kind: "link",
        entry,
        backup: false,
        priority: 30,
      },
    });
    return steps;
  }

  // Case 3: Managed leaf transition (leaf in both old and new)
  if (inOld && inNew) {
    const oldE = oldEntry!;
    const entry = newEntry!;

    if (!fs) {
      // Missing symlink; recreate it without backup.
      steps.push({
        type: "action",
        action: {
          kind: "link",
          entry,
          backup: false,
          priority: 20,
        },
      });
      return steps;
    }

    if (fs.isSymlink) {
      const realPath = await Deno.realPath(fullTargetPath).catch(() => null);

      if (realPath === oldE.source) {
        // Exactly the symlink we previously created.
        if (entry.source === oldE.source) {
          // Nothing changed (same source); no action required.
          return steps;
        }

        // Same target, new source → replace symlink without backup.
        steps.push({
          type: "action",
          action: {
            kind: "link",
            entry,
            backup: false,
            priority: 30,
          },
        });
        return steps;
      }

      // Symlink but not the one recorded in the old manifest.
      if (!entry.forced) {
        // Non-forced and now a different symlink exists at a leaf → fatal collision.
        steps.push({
          type: "error",
          error: {
            type: "error",
            category: "fatal_collision",
            message:
              `Managed path '${fullTargetPath}' is now a different symlink; refusing to overwrite without 'forced = true'.`,
            entry,
            targetPath: fullTargetPath,
            details:
              "The previous generation recorded this target as managed, but it now points to a different symlink target.",
          },
        });
        return steps;
      }

      // forced = true: we will replace it below without backup.
    } else {
      // Non-symlink file/dir at leaf.
      if (!entry.forced) {
        // Non-forced: backup then overwrite.
        steps.push({
          type: "action",
          action: {
            kind: "link",
            entry,
            backup: true,
            priority: 30,
          },
        });
        return steps;
      }
      // forced: we will replace it below without backup.
    }

    // forced = true, any kind of existing fs entry at leaf: remove + link (no backup).
    steps.push({
      type: "action",
      action: {
        kind: "link",
        entry,
        backup: false,
        priority: 30,
      },
    });
    return steps;
  }

  return steps;
}

async function plan(
  newManifest: Manifest,
  oldManifest?: Manifest | null,
): Promise<ActivationPlan> {
  const warnings: ValidationWarning[] = [];
  const errors: ValidationError[] = [];
  const actions: PlannedAction[] = [];

  const old = oldManifest ?? {};

  const allTargets = new Set<string>([
    ...Object.keys(old),
    ...Object.keys(newManifest),
  ]);

  for (const target of allTargets) {
    const oldEntry = old[target] ?? null;
    const newEntry = newManifest[target] ?? null;

    // If neither manifest knows about this target (should not happen), skip.
    if (!oldEntry && !newEntry) {
      continue;
    }

    // Pick the "active" entry for role checks
    const activeEntry = newEntry ?? oldEntry!;
    const isRoot = activeEntry.recursiveRoot === activeEntry.target;

    const fullTargetPath = path.join(HOME, target);
    const fs = await getFileOrNull(fullTargetPath);

    // Dispatch to appropriate handler based on whether this is a root or leaf
    const steps = isRoot
      ? await planRootTransition(target, fullTargetPath, oldEntry, newEntry, fs)
      : await planLeafTransition(
        target,
        fullTargetPath,
        oldEntry,
        newEntry,
        fs,
      );

    // Collect results from the handler
    for (const step of steps) {
      if (step.type === "action") {
        actions.push(step.action);
      } else if (step.type === "warning") {
        warnings.push(step.warning);
      } else if (step.type === "error") {
        errors.push(step.error);
      }
    }
  }

  // Sort actions by priority so cleanup runs before linking, etc.
  actions.sort((a, b) => a.priority - b.priority);

  return { actions, warnings, errors };
}

async function execute({ actions }: ActivationPlan) {
  for (const action of actions) {
    let fileName = "[unknown file]";
    try {
      if (action.kind === "remove") {
        fileName = action.target;
        const fullTargetPath = path.join(HOME, action.target);

        try {
          await Deno.remove(fullTargetPath);
          debugLog("[execute] removed", fullTargetPath);
        } catch (error) {
          if (error instanceof Deno.errors.NotFound) {
            debugLog(
              `[execute] ${fullTargetPath} already gone, skipping remove`,
            );
          } else {
            throw error;
          }
        }

        if (action.removeParents) {
          // Prune empty parent directories up to HOME
          for (
            let currentDir = path.dirname(fullTargetPath);
            currentDir !== HOME && currentDir.startsWith(HOME);
            currentDir = path.dirname(currentDir)
          ) {
            try {
              await Deno.remove(currentDir);
              debugLog(`[execute] Removed empty directory ${currentDir}`);
            } catch (error) {
              if (error instanceof Deno.errors.NotFound) {
                debugLog(
                  `[execute] deleting directory ${currentDir} but not found, skipping`,
                );
                continue;
              }
              const err = error as Error;
              debugLog(
                `[execute] Could not remove directory ${currentDir}, stopping cleanup: ${err.message}`,
              );
              break;
            }
          }
        }
      } else if (action.kind === "link") {
        fileName = action.entry.target;
        const fullTargetPath = path.join(HOME, fileName);
        const targetDir = path.dirname(fullTargetPath);

        await Deno.mkdir(targetDir, { recursive: true });

        // Handle backup / prior content if requested
        if (action.backup) {
          const backupPath = `${fullTargetPath}.stash.bak`;
          debugLog(
            `[execute] backing up existing ${fullTargetPath} to ${backupPath}`,
          );
          try {
            await Deno.rename(fullTargetPath, backupPath);
          } catch (error) {
            if (error instanceof Deno.errors.NotFound) {
              // Nothing to back up; fine.
              debugLog(
                `[execute] no existing file at ${fullTargetPath} to back up`,
              );
            } else {
              throw error;
            }
          }
        } else {
          // Best-effort removal of any existing entry before linking
          try {
            await Deno.remove(fullTargetPath);
          } catch (error) {
            if (!(error instanceof Deno.errors.NotFound)) {
              throw error;
            }
          }
        }

        // Atomic symlink replacement: create tmp link then rename
        const tmpLinkPath = `${fullTargetPath}.stash.tmp`;
        await Deno.remove(tmpLinkPath).catch(() => {});
        await Deno.symlink(action.entry.source, tmpLinkPath);
        await Deno.rename(tmpLinkPath, fullTargetPath);

        debugLog(
          `[execute] linked ${fullTargetPath} -> ${action.entry.source} (backup=${action.backup})`,
        );
      } else {
        // @ts-ignore sanity check
        console.warn("Unknown action", action.kind, action);
      }
    } catch (error) {
      console.error(
        `Error dealing with ${fileName}:`,
        error instanceof Error ? error.message : error,
      );
      // You can decide whether to rethrow here; for now, keep going.
    }
  }
}

async function activate() {
  debugLog("[activate] starting activation");

  // Build the new manifest from the generation config (newGenConfig)
  // by expanding each configured entry.
  const newManifestEntries: ManifestEntry[] = [];
  const expandWarnings: ValidationWarning[] = [];

  for (const entry of Object.values(newGenConfig.files)) {
    const { entries, warnings } = await expandEntry(entry, newGenConfig);
    debugLog(
      "[activate] expanded entry result",
      { entry, entries, warnings },
    );
    newManifestEntries.push(...entries);
    expandWarnings.push(...warnings);
  }

  // Turn the list into a manifest map keyed by target path
  const newManifest: Manifest = {};
  for (const entry of newManifestEntries) {
    newManifest[entry.target] = entry;
  }

  debugLog(
    "[activate] constructed new manifest with",
    Object.keys(newManifest).length,
    "entries",
  );

  // Plan activation: compare old vs new manifests and current filesystem
  const planResult = await plan(newManifest, oldManifest);
  const { actions, warnings, errors } = planResult;

  debugLog(
    "[activate] planning complete",
    { actions, warnings, errors },
  );

  // Log expand warnings
  for (const warning of expandWarnings) {
    console.warn("WARNING (expand):", warning);
  }

  // Log plan warnings during activation
  for (const warning of warnings) {
    console.warn("WARNING (plan):", warning);
  }

  if (errors.length > 0) {
    console.error(`ERROR: ${errors.length} activation error(s) found:`);
    for (const error of errors) {
      console.error("  ERROR:", error);
    }

    debugLog(
      "[activate] fatal plan errors (test mode):",
      errors,
    );

    throw new Error(`Fatal activation errors found`);
  }

  debugLog(
    `[activate] no fatal errors, executing ${actions.length} planned actions`,
  );

  // Execute the planned actions (remove/backup/link)
  await execute(planResult);

  // Persist the new manifest only after successful execution
  await Deno.writeTextFile(
    newManifestPath,
    JSON.stringify(newManifest, null, 4),
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
      "[main] newGenConfig:",
      newGenConfig,
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
