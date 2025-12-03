#! /usr/bin/env -S deno run -A

import * as path from "jsr:@std/path@1.1.2";
import { parseArgs } from "jsr:@std/cli@1.0.24";

const SUBCOMMANDS = ["sync", "help"] as const;
type Subcommand = (typeof SUBCOMMANDS)[number];

function printUsage() {
  console.log(`stash - Declarative symlink manager for NixOS

USAGE:
    stash <COMMAND>

COMMANDS:
    sync    Re-run activation to update symlinks for dynamic/recursive entries
    help    Show this help message

DESCRIPTION:
    The sync command re-runs the activation script using the current generation.
    This is useful when files have been added or removed from recursively-linked
    directories (stashes), as it updates the symlinks without requiring a full
    NixOS rebuild.

EXAMPLES:
    stash sync
        Update symlinks based on the current generation's configuration
`);
}

async function getStatePath(): Promise<string> {
  const home = Deno.env.get("HOME");
  if (!home) {
    throw new Error("HOME environment variable is not set");
  }

  const xdgState = Deno.env.get("XDG_STATE_HOME") ||
    path.join(home, ".local/state");
  return path.join(xdgState, "stash");
}

async function getCurrentGeneration(): Promise<string> {
  const statePath = await getStatePath();
  const currentHomePath = path.join(statePath, "gcroots", "current-home");

  try {
    const stat = await Deno.lstat(currentHomePath);
    if (!stat.isSymlink) {
      throw new Error(`${currentHomePath} exists but is not a symlink`);
    }

    // Read the symlink target to get the actual generation path
    const target = await Deno.readLink(currentHomePath);
    return target;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      throw new Error(
        `No current generation found at ${currentHomePath}.\n` +
          "Have you run stash activation at least once? " +
          "This typically happens on first boot or if stash has never been activated.",
      );
    }
    throw error;
  }
}

async function sync() {
  console.log("Finding current generation...");

  const generationPath = await getCurrentGeneration();
  console.log(`Current generation: ${generationPath}`);

  const activateScriptPath = path.join(generationPath, "activate");

  // Verify the activation script exists
  try {
    await Deno.stat(activateScriptPath);
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      throw new Error(
        `Activation script not found at ${activateScriptPath}.\n` +
          "This generation may have been created before the sync feature was available.\n" +
          "Please run a NixOS rebuild to create a new generation with sync support.",
      );
    }
    throw error;
  }

  console.log("Running activation...\n");

  // The activate wrapper already has the generation path baked in via makeWrapper
  const command = new Deno.Command(activateScriptPath, {
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });

  const result = await command.output();

  if (!result.success) {
    throw new Error(`Activation failed with exit code ${result.code}`);
  }

  console.log("\nSync complete!");
}

async function main() {
  // Find where subcommand starts (first arg that doesn't start with -)
  let subcommandStart = Deno.args.findIndex((arg) => !arg.startsWith("-"));
  subcommandStart = subcommandStart >= 0 ? subcommandStart : Deno.args.length;

  const mainArgs = parseArgs(Deno.args.slice(0, subcommandStart), {
    boolean: ["help", "version"],
    alias: { h: "help", v: "version" },
  });

  const subcommand = Deno.args[subcommandStart] as Subcommand | undefined;
  const subcommandArgs = parseArgs(
    Deno.args.slice(subcommandStart + 1, Deno.args.length),
    {},
  );

  // Handle top-level flags
  if (mainArgs.help || subcommand === "help" || subcommand === undefined) {
    printUsage();
    Deno.exit(0);
  }

  if (mainArgs.version) {
    console.log("stash version 0.1.0");
    Deno.exit(0);
  }

  // Validate subcommand
  if (!SUBCOMMANDS.includes(subcommand as Subcommand)) {
    console.error(`Unknown command: ${subcommand}`);
    console.error(`Run 'stash help' for usage information.`);
    Deno.exit(1);
  }

  try {
    switch (subcommand) {
      case "sync":
        await sync();
        break;
    }
  } catch (error) {
    if (error instanceof Error) {
      console.error(`Error: ${error.message}`);
    } else {
      console.error(`Error: ${error}`);
    }
    Deno.exit(1);
  }
}

if (import.meta.main) {
  main();
}
