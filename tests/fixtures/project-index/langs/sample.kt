package com.example.sample

const val LIMIT = 3
val topLevel = "fun fake() {}"

class Sample(val id: Int) {
    var name: String = ""
    fun run(a: Int) { val local = a }
    fun run(s: String) {}
    companion object {
        fun create(): Sample = Sample(0)
    }
}

interface Listener { fun onEvent() }
object Registry { val items = listOf<Int>() }
enum class State { ON, OFF }
typealias Handler = (Int) -> Unit
fun topFunction(): Int = 1
