package com.example.sample;

// class NotAClass {}
public class Sample {
    public static final int LIMIT = 3;
    private String name;
    public Sample() {}
    public void run(int a) { int local = a; }
    public void run(String s) {}
    interface Listener { void onEvent(); }
    enum State { ON, OFF }
    record Pair(int left, int right) {}
}
