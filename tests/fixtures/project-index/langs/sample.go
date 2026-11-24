// Package sample: func NotADecl() {} in a comment.
package sample

import "fmt"

const MaxAlloc = 10

const (
	ModeA = iota
	ModeB
)

var DefaultConfig = "func Fake() {}"

type AllocConfig struct {
	Name  string
	limit int
}

type Allocator interface {
	Allocate(n int) error
}

type Alias = AllocConfig

/* 😀 emoji */ func GetAllocConf(x int) *AllocConfig {
	local := 1
	_ = local
	return nil
}

func (c *AllocConfig) ToAlloc() int { return 0 }

func (c AllocConfig) String() string { return fmt.Sprint(c.Name) }
