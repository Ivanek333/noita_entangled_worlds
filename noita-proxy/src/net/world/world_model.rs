use super::RunLengthUpdate;
use chunk::{Chunk, Pixel, PixelFlags};
use image::{Rgb, RgbImage};
use std::collections::{HashMap, HashSet};

mod chunk;

const CHUNK_SIZE: usize = 256;

type ChunkCoord = (i32, i32);

pub struct WorldModel {
    chunks: HashMap<ChunkCoord, Chunk>,
    pub mats: HashSet<i16>,
    palette: MatPalette,
    changed_chunks: HashSet<ChunkCoord>,
}

struct MatPalette {
    colors: Vec<Rgb<u8>>,
}

impl MatPalette {
    fn new() -> Self {
        let raw_data = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/assets/mat_colors.txt"
        ));

        let mut colors = Vec::new();

        for line in raw_data.split_ascii_whitespace() {
            let num: u32 = line.parse().unwrap();
            let color = Rgb::from([(num >> 16) as u8, (num >> 8) as u8, num as u8]);
            colors.push(color);
        }
        Self { colors }
    }
}

impl WorldModel {
    fn to_chunk_coords(x: i32, y: i32) -> (ChunkCoord, usize) {
        let chunk_x = x.div_euclid(CHUNK_SIZE as i32);
        let chunk_y = y.div_euclid(CHUNK_SIZE as i32);
        let x = x.rem_euclid(CHUNK_SIZE as i32) as usize;
        let y = y.rem_euclid(CHUNK_SIZE as i32) as usize;
        let offset = x + y * CHUNK_SIZE;
        ((chunk_x, chunk_y), offset)
    }

    fn set_pixel(&mut self, x: i32, y: i32, pixel: Pixel) {
        self.mats.insert(pixel.material);
        let (chunk_coord, offset) = Self::to_chunk_coords(x, y);
        let chunk = self.chunks.entry(chunk_coord).or_default();
        let current = chunk.pixel(offset);
        if current != pixel {
            chunk.set_pixel(offset, pixel);
        }
    }

    fn get_pixel(&self, x: i32, y: i32) -> Pixel {
        let (chunk_coord, offset) = Self::to_chunk_coords(x, y);
        self.chunks
            .get(&chunk_coord)
            .map(|chunk| chunk.pixel(offset))
            .unwrap_or_default()
    }

    pub fn new() -> Self {
        Self {
            chunks: Default::default(),
            mats: Default::default(),
            palette: MatPalette::new(),
            changed_chunks: Default::default(),
        }
    }

    pub fn apply_noita_update(&mut self, update: &RunLengthUpdate) {
        let header = &update.header;
        let runs = &update.runs;

        let mut x = 0;
        let mut y = 0;

        for run in runs {
            let flags = if run.flags > 0 {
                PixelFlags::Fluid
            } else {
                PixelFlags::Normal
            };
            for _ in 0..(u32::from(run.length) + 1) {
                self.set_pixel(
                    header.x + x,
                    header.y + y,
                    Pixel {
                        material: run.material,
                        flags,
                    },
                );
                x += 1;
                if x == i32::from(header.w) + 1 {
                    x = 0;
                    y += 1;
                }
            }
        }
    }

    pub fn get_start(&self) -> (i32, i32) {
        let cx = self.chunks.keys().map(|v| v.0).min().unwrap_or_default();
        let cy = self.chunks.keys().map(|v| v.1).min().unwrap_or_default();
        (cx * CHUNK_SIZE as i32, cy * CHUNK_SIZE as i32)
    }

    pub fn gen_image(&self, x: i32, y: i32, w: u32, h: u32) -> RgbImage {
        RgbImage::from_fn(w, h, |lx, ly| {
            let pixel = self.get_pixel(x + lx as i32, y + ly as i32);
            // let b = if pixel.material != 0 { 255 } else { 0 };
            // Rgb([pixel.material as u8, (pixel.material >> 8) as u8, b])
            let mat_color = self
                .palette
                .colors
                .get(usize::try_from(pixel.material).unwrap_or_default())
                .copied()
                .unwrap_or(Rgb([0, 0, 0]));
            if pixel.flags != PixelFlags::Unknown {
                mat_color
            } else {
                Rgb([25, 0, 0])
            }
        })
    }
}
