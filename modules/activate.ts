#! /usr/bin/env -S deno run --allow-env=HOME

import * as path from "jsr:@std/path@1.1.2";
import { walk } from "jsr:@std/fs@1.0.19"

// read: <static file derivation>, each stash's path
// write: $HOME

// nix-store --add-root creates the in between directories as well

// 1. Check collisions; a collision occurs if
//   - target exists AND
//   - forced != true AND
//   - source != target (in content, cmp -s) AND
//   - backup not configured or impossible (backup alr exists)
// 2. Clean up old gen's links
//   - Delete links in the old generation NOT in the new generation (cmp by source path)
//   - Recursively delete old directories
// 3. Make new gen's links
//   - Backup target path if it exists and not a symlink (and backups enabled)
//   - If source == target don't symlink, not necessary
//   - place symlink with --force (so target path matches new gen)

if (Deno.args.length !== 1) {
    throw new Error("usage: activate.ts [activation package]");
}

async function getFileOrNull(path: string): Promise<Deno.FileInfo | null>;
async function getFileOrNull<T>(
  path: string, 
  process: (data: Deno.FileInfo) => T
): Promise<T | null>;
async function getFileOrNull<T>(
  path: string, 
  process: (data: Deno.FileInfo) => T = (data: Deno.FileInfo) => data as T
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
    source: string,
    target: string,
    recursive: boolean,
    static: boolean,
    forced?: boolean
};

interface CollisionData {
    collision: boolean,
    backup?: boolean,
    skip?: boolean,
    reason?: string
} 

enum CollisionType {
    Nothing = 0,
    Collision = 1, // target exits already
    Overwrite = 1 << 1, // can be overwritten safely
    Backup = 1 << 2, // should be backed up beforehand
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
    source: string,
    target: string,
    parent: string | null,
    static: boolean,
}

const newGeneration = Deno.args[0];
const newGenData: Record<string, StashEntry> = JSON.parse(await Deno.readTextFile(`${newGeneration}/stash.json`));
const newGenStaticFiles = `${newGeneration}/static-files`;

const stashFiles = newGenData;
const HOME = Deno.env.get('HOME')!;

console.debug(`HOME: ${HOME}`);

if (!HOME) {
    throw new Error("$HOME must be set.");
}

const statePath = Deno.env.get('XDG_STATE_HOME') || path.join(HOME, '.local/state/stash'); 
const gcRootsPath = path.join(statePath, 'gcroots');
const oldGenPath = path.join(gcRootsPath, 'current-home');
const oldGenDataPath = path.join(oldGenPath, 'stash.json');
const oldGenData = await getFileOrNull<Promise<Record<string, StashEntry>>>(oldGenDataPath, async (_) => {
    const data = await Deno.readTextFile(oldGenDataPath);
    return JSON.parse(data);
});

const oldManifestPath = path.join(statePath, 'manifest.json');
const newManifestPath = path.join(statePath, 'new-manifest.json');

const oldManifest = await getFileOrNull<Promise<Record<string, ManifestEntry>>>(oldManifestPath, async (_) => {
    const data = await Deno.readTextFile(oldManifestPath);
    return JSON.parse(data);
});

async function isCollision(file: StashEntry): Promise<CollisionType> {
    const fullTargetPath = path.join(HOME, file.target);
    const targetStat = await getFileOrNull(fullTargetPath);

    if (targetStat === null) return CollisionType.Nothing;
    // If file is marked as forced, ignore collision check and overwrite
    if (file.forced) return CollisionType.Forced;

    // Target location exists
    const resolvedPath = await Deno.realPath(fullTargetPath);
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
        ]
    })).output();
    
    // files identical - collision, but it shouldn't be overwritten either
    if (code === 0) return CollisionType.IdenticalFiles;
    // Files are different
    // only mark for backup if target isn't a symlink
    else if (code === 1) return targetStat.isSymlink ? CollisionType.SymlinkAtTarget : CollisionType.FileAtTarget;
    else {
        console.error(`error running cmp -s ${file.source} ${resolvedPath}: code ${code}`);
        throw new Error(`cmp command failed with code ${code}`);
    }
}

async function linkFile(data: { file: StashEntry, collision: CollisionType }) {
    const filesToLink: ManifestEntry[] = await (async () => {
        const { file } = data;
        if (file.recursive) {
            const files = await Array.fromAsync(walk(file.source, {
                followSymlinks: false,
                includeDirs: false
            }));

            return files.map(f => {
                const relativePath = path.relative(file.source, f.path);
                return {
                    source: f.path, 
                    target: `${relativePath}${file.target}`,
                    parent: file.target,
                    static: file.static,
                    recursive: true,
                }
            });
        } else {
            return [{
                source: file.source,
                target: file.target,
                parent: null,
                static: file.static,
                recursive: false,
            }]
        }
    })();

    const { collision } = data;
    filesToLink.forEach(async (file) => {
        const fullTargetPath = path.join(HOME, file.target);
        if (collision & CollisionType.Fatal) {
            console.error(`Cannot continue: file at ${fullTargetPath} would be overwritten`);
        }

        if (collision === CollisionType.IdenticalFiles) {
            console.debug(`Skipping linking ${fullTargetPath}, identical to ${file.source}`);
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
        await Deno.symlink(file.source, tmpLinkPath);
        await Deno.rename(tmpLinkPath, fullTargetPath);
    });

    return filesToLink;
}

// files with collision data added on
const files = await Promise.all(Object.values(newGenData).map(async (file) => {
    return {
        data: file,
        collision: await isCollision(file)
    };
}));

const collisions = files.filter(file => file.collision & CollisionType.Fatal);

if (collisions.length > 0) {
    console.error(`ERROR: ${collisions.length} collision(s) found: `);
    console.error(collisions);
}



