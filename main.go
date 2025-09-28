package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strconv"
	"sync"
	"time"
	"unsafe"

	"github.com/openfluke/paragon/v3"
)

var (
	mu      sync.Mutex
	nextID  int64 = 1
	objects       = map[int64]interface{}{}
)

func put(o interface{}) int64 {
	mu.Lock()
	defer mu.Unlock()
	id := nextID
	nextID++
	objects[id] = o
	return id
}

func get(id int64) (interface{}, bool) {
	mu.Lock()
	defer mu.Unlock()
	o, ok := objects[id]
	return o, ok
}

func del(id int64) {
	mu.Lock()
	defer mu.Unlock()
	delete(objects, id)
}

func cstr(s string) *C.char        { return C.CString(s) }
func asJSON(v interface{}) *C.char { b, _ := json.Marshal(v); return C.CString(string(b)) }
func errJSON(msg string) *C.char {
	return asJSON(map[string]string{"error": msg})
}

// Dynamic parameter conversion (like WASM bridge)
func convertParameter(param interface{}, expectedType reflect.Type, paramIndex int) (reflect.Value, error) {
	switch expectedType.Kind() {
	case reflect.Slice:
		return convertSlice(param, expectedType, paramIndex)
	case reflect.Map:
		return convertMap(param, expectedType, paramIndex)

	// Integers
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		switch v := param.(type) {
		case float64:
			return reflect.ValueOf(int64(v)).Convert(expectedType), nil
		case float32:
			return reflect.ValueOf(int64(v)).Convert(expectedType), nil
		case int, int8, int16, int32, int64:
			return reflect.ValueOf(v).Convert(expectedType), nil
		default:
			return reflect.Value{}, fmt.Errorf("parameter %d: expected int, got %T", paramIndex, param)
		}

	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		switch v := param.(type) {
		case float64:
			return reflect.ValueOf(uint64(v)).Convert(expectedType), nil
		case float32:
			return reflect.ValueOf(uint64(v)).Convert(expectedType), nil
		case uint, uint8, uint16, uint32, uint64:
			return reflect.ValueOf(v).Convert(expectedType), nil
		default:
			return reflect.Value{}, fmt.Errorf("parameter %d: expected uint, got %T", paramIndex, param)
		}

	case reflect.Float32, reflect.Float64:
		switch v := param.(type) {
		case float64:
			return reflect.ValueOf(v).Convert(expectedType), nil
		case float32:
			return reflect.ValueOf(v).Convert(expectedType), nil
		default:
			return reflect.Value{}, fmt.Errorf("parameter %d: expected float, got %T", paramIndex, param)
		}

	case reflect.Bool:
		if v, ok := param.(bool); ok {
			return reflect.ValueOf(v), nil
		}
		return reflect.Value{}, fmt.Errorf("parameter %d: expected bool, got %T", paramIndex, param)

	case reflect.String:
		if v, ok := param.(string); ok {
			return reflect.ValueOf(v), nil
		}
		return reflect.Value{}, fmt.Errorf("parameter %d: expected string, got %T", paramIndex, param)

	default:
		// time.Duration special case
		if expectedType == reflect.TypeOf(time.Duration(0)) {
			switch v := param.(type) {
			case float64:
				return reflect.ValueOf(time.Duration(v)), nil
			case float32:
				return reflect.ValueOf(time.Duration(v)), nil
			}
			return reflect.Value{}, fmt.Errorf("parameter %d: expected duration number, got %T", paramIndex, param)
		}
		// struct via map → JSON → struct
		if expectedType.Kind() == reflect.Struct {
			if m, ok := param.(map[string]interface{}); ok {
				b, _ := json.Marshal(m)
				holder := reflect.New(expectedType).Interface()
				if err := json.Unmarshal(b, holder); err != nil {
					return reflect.Value{}, fmt.Errorf("parameter %d: struct decode: %v", paramIndex, err)
				}
				return reflect.ValueOf(holder).Elem(), nil
			}
		}
		return reflect.Zero(expectedType), fmt.Errorf("parameter %d: unsupported type %s", paramIndex, expectedType.String())
	}
}

func convertSlice(param interface{}, expectedType reflect.Type, paramIndex int) (reflect.Value, error) {
	val, ok := param.([]interface{})
	if !ok {
		// Coerce a single number into a 1-length slice
		if n, ok := param.(float64); ok {
			s := reflect.MakeSlice(expectedType, 1, 1)
			elem, err := convertParameter(n, expectedType.Elem(), paramIndex)
			if err != nil {
				return reflect.Value{}, err
			}
			s.Index(0).Set(elem)
			return s, nil
		}
		return reflect.Value{}, fmt.Errorf("parameter %d: expected slice, got %T", paramIndex, param)
	}

	elemType := expectedType.Elem()
	out := reflect.MakeSlice(expectedType, len(val), len(val))
	for i, raw := range val {
		if elemType.Kind() == reflect.Slice {
			conv, err := convertSlice(raw, elemType, paramIndex)
			if err != nil {
				return reflect.Value{}, err
			}
			out.Index(i).Set(conv)
			continue
		}
		if elemType.Kind() == reflect.Struct {
			if m, ok := raw.(map[string]interface{}); ok {
				b, _ := json.Marshal(m)
				holder := reflect.New(elemType).Interface()
				if err := json.Unmarshal(b, holder); err != nil {
					return reflect.Value{}, fmt.Errorf("parameter %d: struct element decode: %v", paramIndex, err)
				}
				out.Index(i).Set(reflect.ValueOf(holder).Elem())
				continue
			}
			return reflect.Value{}, fmt.Errorf("parameter %d: invalid struct element %T", paramIndex, raw)
		}
		elem, err := convertParameter(raw, elemType, paramIndex)
		if err != nil {
			return reflect.Value{}, err
		}
		out.Index(i).Set(elem)
	}
	return out, nil
}

func convertMap(param interface{}, expectedType reflect.Type, paramIndex int) (reflect.Value, error) {
	jm, ok := param.(map[string]interface{})
	if !ok {
		return reflect.Value{}, fmt.Errorf("parameter %d: expected map, got %T", paramIndex, param)
	}
	keyT := expectedType.Key()
	valT := expectedType.Elem()
	out := reflect.MakeMap(expectedType)

	for keyStr, raw := range jm {
		var keyV reflect.Value
		switch keyT.Kind() {
		case reflect.String:
			keyV = reflect.ValueOf(keyStr)
		case reflect.Int:
			i, err := strconv.Atoi(keyStr)
			if err != nil {
				return reflect.Value{}, fmt.Errorf("parameter %d: bad map key %q", paramIndex, keyStr)
			}
			keyV = reflect.ValueOf(i)
		default:
			return reflect.Value{}, fmt.Errorf("parameter %d: unsupported map key type %s", paramIndex, keyT)
		}
		valV, err := convertParameter(raw, valT, paramIndex)
		if err != nil {
			return reflect.Value{}, err
		}
		out.SetMapIndex(keyV, valV)
	}
	return out, nil
}

// Dynamic method calling with JSON arguments
func callMethodWithJSON(target reflect.Value, argsJSON string) *C.char {
	mt := target.Type()
	want := mt.NumIn()

	// Parse argsJSON as array of parameters
	var params []interface{}
	if argsJSON == "" || argsJSON == "[]" {
		params = nil
	} else if err := json.Unmarshal([]byte(argsJSON), &params); err != nil {
		// If not an array, try single element
		var single interface{}
		if err2 := json.Unmarshal([]byte(argsJSON), &single); err2 != nil {
			return errJSON("Invalid JSON input: " + err.Error())
		}
		params = []interface{}{single}
	}

	if len(params) != want {
		return errJSON(fmt.Sprintf("Expected %d parameters, got %d", want, len(params)))
	}

	in := make([]reflect.Value, want)
	for i := 0; i < want; i++ {
		exp := mt.In(i)
		val, err := convertParameter(params[i], exp, i)
		if err != nil {
			return errJSON(err.Error())
		}
		in[i] = val
	}

	defer func() {
		if r := recover(); r != nil {
			// Handle panics gracefully
		}
	}()

	out := target.Call(in)
	res := make([]interface{}, len(out))
	for i := range out {
		res[i] = out[i].Interface()
	}
	return asJSON(res)
}

// Dynamic method wrapper for any object
func wrapObjectMethods(obj interface{}) map[string]*C.char {
	methods := make(map[string]*C.char)
	val := reflect.ValueOf(obj)
	typ := val.Type()

	for i := 0; i < typ.NumMethod(); i++ {
		method := typ.Method(i)
		// Only export public methods
		if method.Name[0] >= 'A' && method.Name[0] <= 'Z' {
			methodName := method.Name
			methodValue := val.Method(i)

			// Create a closure for each method
			methods[methodName] = asJSON(map[string]interface{}{
				"name": methodName,
				"type": methodValue.Type().String(),
			})
		}
	}
	return methods
}

// C ABI Exports

//export Paragon_NewNetworkFloat32
func Paragon_NewNetworkFloat32(
	layersJSON, activationsJSON, fullyJSON *C.char,
	useGPU C.bool,
	debug C.bool,
) *C.char {
	var layers []struct{ Width, Height int }
	var acts []string
	var fully []bool

	if err := json.Unmarshal([]byte(C.GoString(layersJSON)), &layers); err != nil {
		return errJSON("layers: " + err.Error())
	}
	if err := json.Unmarshal([]byte(C.GoString(activationsJSON)), &acts); err != nil {
		return errJSON("activations: " + err.Error())
	}
	if err := json.Unmarshal([]byte(C.GoString(fullyJSON)), &fully); err != nil {
		return errJSON("fullyConnected: " + err.Error())
	}

	net, err := paragon.NewNetwork[float32](layers, acts, fully)
	if err != nil {
		return errJSON("new network: " + err.Error())
	}

	// Defaults first
	net.WebGPUNative = false
	net.Debug = bool(debug)

	var gpuInitOK bool
	var gpuInitMs int64

	if bool(useGPU) {
		startGPU := time.Now()
		net.WebGPUNative = true
		if err := net.InitializeOptimizedGPU(); err != nil {
			// Fall back to CPU if init fails
			net.WebGPUNative = false
			gpuInitOK = false
			gpuInitMs = time.Since(startGPU).Milliseconds()
		} else {
			gpuInitOK = true
			gpuInitMs = time.Since(startGPU).Milliseconds()
			// IMPORTANT: do NOT CleanupOptimizedGPU here—caller owns the handle.
		}
	}

	id := put(net)
	return asJSON(map[string]interface{}{
		"handle":      id,
		"type":        "Network[float32]",
		"layers":      len(layers),
		"gpu":         net.WebGPUNative,
		"gpu_init_ok": gpuInitOK,
		"gpu_init_ms": gpuInitMs,
		"debug":       net.Debug,
	})
}

//export Paragon_Call
func Paragon_Call(handle int64, method *C.char, argsJSON *C.char) *C.char {
	obj, ok := get(handle)
	if !ok {
		return errJSON(fmt.Sprintf("invalid handle %d", handle))
	}

	methodName := C.GoString(method)
	m := reflect.ValueOf(obj).MethodByName(methodName)
	if !m.IsValid() {
		return errJSON("Method not found: " + methodName)
	}

	return callMethodWithJSON(m, C.GoString(argsJSON))
}

//export Paragon_ListMethods
func Paragon_ListMethods(handle int64) *C.char {
	obj, ok := get(handle)
	if !ok {
		return errJSON("invalid handle")
	}

	val := reflect.ValueOf(obj)
	typ := val.Type()
	methods := make([]map[string]interface{}, 0)

	for i := 0; i < typ.NumMethod(); i++ {
		method := typ.Method(i)
		if method.Name[0] >= 'A' && method.Name[0] <= 'Z' {
			methodType := method.Type
			params := make([]string, methodType.NumIn()-1) // -1 for receiver
			for j := 1; j < methodType.NumIn(); j++ {
				params[j-1] = methodType.In(j).String()
			}
			returns := make([]string, methodType.NumOut())
			for j := 0; j < methodType.NumOut(); j++ {
				returns[j] = methodType.Out(j).String()
			}

			methods = append(methods, map[string]interface{}{
				"name":       method.Name,
				"parameters": params,
				"returns":    returns,
			})
		}
	}

	return asJSON(map[string]interface{}{
		"methods": methods,
		"count":   len(methods),
	})
}

//export Paragon_GetInfo
func Paragon_GetInfo(handle int64) *C.char {
	obj, ok := get(handle)
	if !ok {
		return errJSON("invalid handle")
	}

	val := reflect.ValueOf(obj)
	typ := val.Type()

	info := map[string]interface{}{
		"type":    typ.String(),
		"kind":    typ.Kind().String(),
		"methods": typ.NumMethod(),
		"handle":  handle,
	}

	// Add network-specific info if it's a network
	if net, ok := obj.(*paragon.Network[float32]); ok {
		info["webgpu_native"] = net.WebGPUNative
		info["debug"] = net.Debug
		// Add more network-specific info as needed
	}

	return asJSON(info)
}

//export Paragon_EnableGPU
func Paragon_EnableGPU(handle int64) *C.char {
	obj, ok := get(handle)
	if !ok {
		return errJSON("invalid handle")
	}

	net, ok := obj.(*paragon.Network[float32])
	if !ok {
		return errJSON("not a Network[float32]")
	}

	net.WebGPUNative = true
	if err := net.InitializeOptimizedGPU(); err != nil {
		net.WebGPUNative = false
		return errJSON("failed to initialize GPU: " + err.Error())
	}

	return asJSON(map[string]interface{}{
		"status": "GPU enabled",
		"handle": handle,
	})
}

//export Paragon_DisableGPU
func Paragon_DisableGPU(handle int64) *C.char {
	obj, ok := get(handle)
	if !ok {
		return errJSON("invalid handle")
	}

	net, ok := obj.(*paragon.Network[float32])
	if !ok {
		return errJSON("not a Network[float32]")
	}

	net.CleanupOptimizedGPU()
	net.WebGPUNative = false

	return asJSON(map[string]interface{}{
		"status": "GPU disabled",
		"handle": handle,
	})
}

//export Paragon_PerturbWeights
func Paragon_PerturbWeights(handle int64, magnitude float64, seed int64) *C.char {
	obj, ok := get(handle)
	if !ok {
		return errJSON("invalid handle")
	}

	net, ok := obj.(*paragon.Network[float32])
	if !ok {
		return errJSON("not a Network[float32]")
	}

	net.PerturbWeights(magnitude, int(seed))
	return asJSON(map[string]string{"status": "weights perturbed"})
}

//export Paragon_Free
func Paragon_Free(handle int64) {
	// Clean up GPU resources if it's a network
	if obj, ok := get(handle); ok {
		if net, ok := obj.(*paragon.Network[float32]); ok {
			net.CleanupOptimizedGPU()
		}
	}
	del(handle)
}

//export Paragon_FreeCString
func Paragon_FreeCString(p *C.char) {
	C.free(unsafe.Pointer(p))
}

//export Paragon_GetVersion
func Paragon_GetVersion() *C.char {
	return cstr("Paragon C ABI v1.0 (float32)")
}

func main() {
	// This is a library, main() should be empty for CGO
}
