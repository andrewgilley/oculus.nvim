use std::env;
use std::path::PathBuf;
use std::process::exit;

use oculus_engine::investigate::Investigator;

fn print_usage() {
    eprintln!("Usage: oculus-engine investigate --repo <path> [--target <ref>] [--target-kind <kind>] [--db <path>]");
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        print_usage();
        exit(1);
    }

    if args[1] == "--version" || args[1] == "-v" {
        println!("oculus-engine {}", env!("CARGO_PKG_VERSION"));
        return;
    }

    if args[1] != "investigate" {
        eprintln!("Unknown command: {}", args[1]);
        print_usage();
        exit(1);
    }

    let mut repo_path: Option<PathBuf> = None;
    let mut target: Option<String> = None;
    let mut target_kind: Option<String> = None;
    let mut db_path: Option<PathBuf> = None;

    let mut i = 2;
    while i < args.len() {
        match args[i].as_str() {
            "--repo" | "-r" => {
                if i + 1 < args.len() {
                    repo_path = Some(PathBuf::from(&args[i + 1]));
                    i += 2;
                } else {
                    eprintln!("Missing argument for --repo");
                    exit(1);
                }
            }
            "--target" | "-t" => {
                if i + 1 < args.len() {
                    target = Some(args[i + 1].clone());
                    i += 2;
                } else {
                    eprintln!("Missing argument for --target");
                    exit(1);
                }
            }
            "--target-kind" | "-k" => {
                if i + 1 < args.len() {
                    target_kind = Some(args[i + 1].clone());
                    i += 2;
                } else {
                    eprintln!("Missing argument for --target-kind");
                    exit(1);
                }
            }
            "--db" => {
                if i + 1 < args.len() {
                    db_path = Some(PathBuf::from(&args[i + 1]));
                    i += 2;
                } else {
                    eprintln!("Missing argument for --db");
                    exit(1);
                }
            }
            _ => {
                eprintln!("Unknown option: {}", args[i]);
                print_usage();
                exit(1);
            }
        }
    }

    let repo = repo_path.unwrap_or_else(|| {
        env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
    });

    match Investigator::run_investigation(
        &repo,
        target.as_deref(),
        target_kind.as_deref(),
        db_path.as_deref(),
    ) {
        Ok(bundle) => {
            match serde_json::to_string_pretty(&bundle) {
                Ok(json) => println!("{}", json),
                Err(e) => {
                    eprintln!("Failed to serialize bundle: {}", e);
                    exit(1);
                }
            }
        }
        Err(e) => {
            eprintln!("Investigation failed: {}", e);
            exit(1);
        }
    }
}
