use std::env;
use std::error::Error;
use std::fs::{File, OpenOptions};
use std::io::{self, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::Path;

const BUFFER_SIZE: usize = 1024 * 1024;

// Bao's incremental encoder needs Read + Write + Seek for its final
// post-order-to-pre-order pass. BufWriter<File> lacks Read, so forward reads
// to the file after flushing any pending writes.
struct BufferedFile(BufWriter<File>);

impl BufferedFile {
    fn create(path: &Path) -> io::Result<Self> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)?;
        Ok(Self(BufWriter::with_capacity(BUFFER_SIZE, file)))
    }
}

impl Read for BufferedFile {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.0.flush()?;
        self.0.get_mut().read(buf)
    }
}

impl Write for BufferedFile {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.0.flush()
    }
}

impl Seek for BufferedFile {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        self.0.seek(pos)
    }
}

fn run(mode: &str, input_path: &Path, output_path: Option<&Path>) -> Result<(), Box<dyn Error>> {
    let mut input = BufReader::with_capacity(BUFFER_SIZE, File::open(input_path)?);
    let root = match mode {
        "hash" => {
            let mut hasher = blake3::Hasher::new();
            let mut buffer = [0_u8; BUFFER_SIZE];
            loop {
                let bytes = input.read(&mut buffer)?;
                if bytes == 0 {
                    break;
                }
                hasher.update(&buffer[..bytes]);
            }
            hasher.finalize()
        }
        "outboard-memory" => {
            let output_path = output_path.ok_or("outboard mode requires an output path")?;
            let capacity = bao::encode::outboard_size(input.get_ref().metadata()?.len()) as usize;
            let mut encoder = bao::encode::Encoder::new_outboard(io::Cursor::new(Vec::with_capacity(capacity)));
            io::copy(&mut input, &mut encoder)?;
            let root = encoder.finalize()?;
            let bytes = encoder.into_inner().into_inner();
            let mut output = BufWriter::with_capacity(BUFFER_SIZE, File::create(output_path)?);
            output.write_all(&bytes)?;
            output.flush()?;
            root
        }
        "outboard" => {
            let output_path = output_path.ok_or("outboard mode requires an output path")?;
            let mut encoder = bao::encode::Encoder::new_outboard(BufferedFile::create(output_path)?);
            io::copy(&mut input, &mut encoder)?;
            let root = encoder.finalize()?;
            encoder.into_inner().flush()?;
            root
        }
        _ => return Err(format!("invalid mode {mode:?}; expected hash or outboard").into()),
    };
    println!("{root}");
    Ok(())
}

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = env::args_os().collect();
    if args.len() < 3 || args.len() > 4 {
        return Err("usage: bao-rust-bench <hash|outboard> <input-path> <output-path>".into());
    }
    let mode = args[1].to_str().ok_or("mode must be UTF-8")?;
    let input = Path::new(&args[2]);
    let output = args.get(3).map(Path::new);
    if let Some(output) = output {
        if input.canonicalize().ok().is_some_and(|path| Some(path) == output.canonicalize().ok()) {
            return Err("input and output must refer to different files".into());
        }
    }
    run(mode, input, output)
}
