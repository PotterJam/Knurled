use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};

use clap::{Parser, Subcommand};
use knurled_core::{
    backtest_repo, build_repo, check_generated_repo, init_training_repo, pretty_json, preview_repo,
    replay_repo, simulate_repo, validate_repo,
};

#[derive(Debug, Parser)]
#[command(name = "knurled")]
#[command(about = "Knurled FitSpec authoring CLI")]
struct Args {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    Init {
        repo: PathBuf,
        #[arg(long, default_value = knurled_core::DEFAULT_TEMPLATE_ID)]
        template: String,
    },
    Validate {
        #[arg(default_value = ".")]
        repo: PathBuf,
    },
    Build {
        #[arg(default_value = ".")]
        repo: PathBuf,
    },
    Preview {
        #[arg(default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value_t = 1)]
        weeks: u32,
    },
    Simulate {
        #[arg(default_value = ".")]
        repo: PathBuf,
        #[arg(long, default_value_t = 8)]
        weeks: u32,
        #[arg(long, default_value = "all-pass")]
        strategy: String,
    },
    Replay {
        #[arg(default_value = ".")]
        repo: PathBuf,
        #[arg(long)]
        write_state: bool,
    },
    CheckGenerated {
        #[arg(default_value = ".")]
        repo: PathBuf,
    },
    Backtest {
        #[arg(default_value = ".")]
        repo: PathBuf,
    },
    Serve {
        #[arg(long, default_value_t = 4321)]
        port: u16,
    },
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    match Args::parse().command {
        Command::Init { repo, template } => {
            let result = init_training_repo(&repo, &template)?;
            println!("Created Knurled training repo: {}", result.root.display());
            println!("Status: {:?}", result.validation.status);
            if let Some(next) = result.next_workout {
                println!("Next workout: {}", next.display_name);
            }
        }
        Command::Validate { repo } => {
            let report = validate_repo(repo)?;
            println!("{}", pretty_json(&report)?);
            if report.status != knurled_core::ValidationStatus::Valid {
                std::process::exit(1);
            }
        }
        Command::Build { repo } => {
            let outputs = build_repo(&repo, true)?;
            println!("Built {}", repo.display());
            println!("Status: {:?}", outputs.validation.status);
        }
        Command::Preview { repo, weeks } => {
            println!("{}", pretty_json(&preview_repo(repo, weeks)?)?);
        }
        Command::Simulate {
            repo,
            weeks,
            strategy,
        } => {
            println!("{}", pretty_json(&simulate_repo(repo, weeks, &strategy)?)?);
        }
        Command::Replay { repo, write_state } => {
            println!("{}", pretty_json(&replay_repo(repo, write_state)?)?);
        }
        Command::CheckGenerated { repo } => {
            let report = check_generated_repo(repo)?;
            if report.status == "current" {
                println!("Generated files are current.");
            } else {
                println!("Generated files are stale.");
                for file in report.missing.iter().chain(&report.changed) {
                    println!("- {file}");
                }
                std::process::exit(1);
            }
        }
        Command::Backtest { repo } => {
            let report = backtest_repo(repo)?;
            println!("{}", pretty_json(&report)?);
            if report.status != "passed" {
                std::process::exit(1);
            }
        }
        Command::Serve { port } => serve(port)?,
    }

    Ok(())
}

fn serve(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    let workbench = Path::new(env!("CARGO_MANIFEST_DIR")).join("../workbench");
    let listener = TcpListener::bind(("127.0.0.1", port))?;
    println!("Knurled workbench: http://localhost:{port}");

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                if let Err(error) = handle_request(stream, &workbench) {
                    eprintln!("request failed: {error}");
                }
            }
            Err(error) => eprintln!("connection failed: {error}"),
        }
    }
    Ok(())
}

fn handle_request(mut stream: TcpStream, root: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let mut buffer = [0; 2048];
    let size = stream.read(&mut buffer)?;
    let request = String::from_utf8_lossy(&buffer[..size]);
    let first_line = request.lines().next().unwrap_or_default();
    let path = first_line
        .split_whitespace()
        .nth(1)
        .unwrap_or("/")
        .split('?')
        .next()
        .unwrap_or("/");
    let path = if path == "/" { "/index.html" } else { path };
    let relative = path.trim_start_matches('/');
    if relative.contains("..") {
        write_response(&mut stream, "400 Bad Request", "text/plain", b"Bad request")?;
        return Ok(());
    }

    let file_path = root.join(relative);
    if !file_path.exists() || file_path.is_dir() {
        write_response(&mut stream, "404 Not Found", "text/plain", b"Not found")?;
        return Ok(());
    }

    let bytes = fs::read(&file_path)?;
    write_response(&mut stream, "200 OK", content_type(&file_path), &bytes)?;
    Ok(())
}

fn write_response(
    stream: &mut TcpStream,
    status: &str,
    content_type: &str,
    body: &[u8],
) -> std::io::Result<()> {
    write!(
        stream,
        "HTTP/1.1 {status}\r\ncontent-type: {content_type}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
        body.len()
    )?;
    stream.write_all(body)
}

fn content_type(path: &Path) -> &'static str {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("html") => "text/html; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("js") => "text/javascript; charset=utf-8",
        Some("png") => "image/png",
        Some("svg") => "image/svg+xml",
        _ => "application/octet-stream",
    }
}
