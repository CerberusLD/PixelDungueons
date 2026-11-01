@tool
class_name CerberusTest
extends RefCounted
## Framework mínimo de tests para Cerberus Engine.
##
## Uso:
##   extends CerberusTest
##
##   func test_suma() -> void:
##       assert_eq(2 + 2, 4, "la suma debe ser 4")
##
## El runner descubre archivos *_test.gd y ejecuta cada método test_*.

var failures: Array = []
var assertions: int = 0


func _suite_name() -> String:
	var s := get_script()
	if s and s.resource_path:
		return s.resource_path.get_file().get_basename()
	return "unnamed"


func before_each() -> void:
	pass


func after_each() -> void:
	pass


# ------------------------------------------------------------------ asserts

func assert_true(condition: bool, message: String = "") -> bool:
	assertions += 1
	if not condition:
		_fail("assert_true", message if not message.is_empty() else "se esperaba true")
		return false
	return true


func assert_false(condition: bool, message: String = "") -> bool:
	return assert_true(not condition, message if not message.is_empty() else "se esperaba false")


func assert_eq(actual: Variant, expected: Variant, message: String = "") -> bool:
	assertions += 1
	if typeof(actual) != typeof(expected) or actual != expected:
		_fail("assert_eq", "%s\n  actual:   %s\n  esperado: %s" % [message, str(actual), str(expected)])
		return false
	return true


func assert_ne(actual: Variant, expected: Variant, message: String = "") -> bool:
	assertions += 1
	if actual == expected and typeof(actual) == typeof(expected):
		_fail("assert_ne", "%s\n  ambos valores son %s" % [message, str(actual)])
		return false
	return true


func assert_null(value: Variant, message: String = "") -> bool:
	assertions += 1
	if value != null:
		_fail("assert_null", "%s\n  valor: %s" % [message, str(value)])
		return false
	return true


func assert_not_null(value: Variant, message: String = "") -> bool:
	assertions += 1
	if value == null:
		_fail("assert_not_null", message if not message.is_empty() else "valor nulo")
		return false
	return true


func assert_almost_eq(actual: float, expected: float, epsilon: float = 0.001, message: String = "") -> bool:
	assertions += 1
	if absf(actual - expected) > epsilon:
		_fail("assert_almost_eq", "%s\n  actual: %f esperado: %f (+-%f)" % [message, actual, expected, epsilon])
		return false
	return true


func assert_in(value: Variant, container: Variant, message: String = "") -> bool:
	assertions += 1
	var found := false
	if container is Array:
		found = container.has(value)
	elif container is Dictionary:
		found = container.has(value)
	elif container is String:
		found = String(container).contains(str(value))
	if not found:
		_fail("assert_in", "%s\n  %s no está en %s" % [message, str(value), str(container)])
		return false
	return true


func fail(message: String) -> void:
	assertions += 1
	_fail("fail", message)


func _fail(kind: String, message: String) -> void:
	failures.append({"kind": kind, "message": message})
	push_error("[CerberusTest] %s: %s" % [kind, message])
