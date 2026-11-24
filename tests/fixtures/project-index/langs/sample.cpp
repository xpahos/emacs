namespace geo {
class Shape {
 public:
  Shape();
  virtual double area() const;
  int sides;
};
struct Point { double x; };
double Shape::area() const { return 0; }
int overload(int a);
int overload(double a);
template <typename T> T identity(T v) { int local = 0; return v; }
enum class Kind { Circle, Square };
using Number = double;
}
