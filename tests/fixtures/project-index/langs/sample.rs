//! fn not_a_decl() {}
pub mod inner {
    pub fn helper() {}
}
pub const MAX: usize = 4;
static GLOBAL: i32 = 0;
pub struct Allocator { pub capacity: usize }
pub enum Mode { Fast, Slow }
pub trait Allocate { fn allocate(&self) -> usize; }
impl Allocator {
    pub fn new() -> Self { let local = 0; Allocator { capacity: local } }
}
impl Allocate for Allocator { fn allocate(&self) -> usize { self.capacity } }
type Size = usize;
macro_rules! make { () => {} }
