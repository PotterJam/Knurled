use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};

use clap::{Parser, Subcommand, ValueEnum};
use knurled_core::{
    ExecutionInput, SubmitMode, active_program_dir, backtest_records_repo, build_repo,
    check_generated_repo, init_training_repo, pretty_json, preview_repo, simulate_repo,
    submit_repo, validate_repo, vendor_template,
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
    CheckGenerated {
        #[arg(default_value = ".")]
        repo: PathBuf,
    },
    /// Submit a finished session: advance state and append the day to the record (ADR 0007).
    Submit {
        repo: PathBuf,
        /// Path to an ExecutionInput JSON built against the current next workout.
        input: PathBuf,
        /// ISO date (YYYY-MM-DD) the session was performed.
        #[arg(long)]
        date: String,
        /// How the session moves state.
        #[arg(long, value_enum, default_value_t = SubmitModeArg::Advance)]
        mode: SubmitModeArg,
    },
    /// Backtest the plan over the recorded days (replay-free projection, ADR 0007).
    BacktestRecords {
        #[arg(default_value = ".")]
        repo: PathBuf,
    },
    /// Manage repository-owned template documents.
    Template {
        #[command(subcommand)]
        command: TemplateCommand,
    },
    Serve {
        #[arg(long, default_value_t = 4321)]
        port: u16,
    },
}

#[derive(Debug, Subcommand)]
enum TemplateCommand {
    /// Copy a pinned built-in document into the active program's templates directory.
    Vendor {
        #[arg(default_value = ".")]
        repo: PathBuf,
        template: String,
        #[arg(long)]
        output: Option<String>,
    },
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum SubmitModeArg {
    /// Run the program's progression rules.
    Advance,
    /// Record only; leave targets/stages/fails unchanged.
    OffDay,
    /// Make the performed loads the new baseline.
    Reset,
}

impl From<SubmitModeArg> for SubmitMode {
    fn from(value: SubmitModeArg) -> Self {
        match value {
            SubmitModeArg::Advance => SubmitMode::Advance,
            SubmitModeArg::OffDay => SubmitMode::OffDay,
            SubmitModeArg::Reset => SubmitMode::Reset,
        }
    }
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
        Command::Submit {
            repo,
            input,
            date,
            mode,
        } => {
            let text = fs::read_to_string(&input)?;
            let execution_input: ExecutionInput = serde_json::from_str(&text)?;
            let outcome = submit_repo(&repo, &execution_input, mode.into(), &date)?;
            println!("{}", pretty_json(&outcome)?);
            if outcome.validation.status != knurled_core::ValidationStatus::Valid {
                std::process::exit(1);
            }
        }
        Command::BacktestRecords { repo } => {
            println!("{}", pretty_json(&backtest_records_repo(repo)?)?);
        }
        Command::Template { command } => match command {
            TemplateCommand::Vendor {
                repo,
                template,
                output,
            } => {
                let program_dir = active_program_dir(&repo)?;
                let templates = program_dir.join("templates");
                fs::create_dir_all(&templates)?;
                let filename = output.unwrap_or_else(|| {
                    format!(
                        "{}.fitspec",
                        template
                            .split('@')
                            .next()
                            .unwrap_or("template")
                            .replace(['.', '/'], "-")
                    )
                });
                if filename.contains("..") || filename.contains('/') || filename.contains('\\') {
                    return Err("template output must be a filename inside templates/".into());
                }
                let path = templates.join(filename);
                fs::write(&path, vendor_template(&template)?)?;
                println!("Vendored {}", path.display());
            }
        },
        Command::Serve { port } => serve(port)?,
    }

    Ok(())
}

fn serve(port: u16) -> Result<(), Box<dyn std::error::Error>> {
    // Serves the Vite build output. Run `npm run build:workbench` first (or use
    // `npm run dev:workbench` for the hot-reloading dev server instead).
    let workbench = Path::new(env!("CARGO_MANIFEST_DIR")).join("../workbench/dist");
    if !workbench.exists() {
        return Err(format!(
            "workbench build not found at {}\nRun `npm run build:workbench` first, or use `npm run dev:workbench` for development.",
            workbench.display()
        )
        .into());
    }
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
        Some("js" | "mjs") => "text/javascript; charset=utf-8",
        Some("json") => "application/json; charset=utf-8",
        Some("wasm") => "application/wasm",
        Some("png") => "image/png",
        Some("svg") => "image/svg+xml",
        _ => "application/octet-stream",
    }
}
