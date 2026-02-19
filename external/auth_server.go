package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"sync"
	"time"
)

type AuthCode struct {
	Code  string `json:"code"`
	Error string `json:"error"`
	State string `json:"state"`
}

var (
	authCode AuthCode
	mu       sync.Mutex
	port     = flag.String("port", "8888", "Port to listen on")
)

func init() {
	flag.Parse()
}

func handleCallback(w http.ResponseWriter, r *http.Request) {
	code := r.URL.Query().Get("code")
	errorParam := r.URL.Query().Get("error")
	state := r.URL.Query().Get("state")

	mu.Lock()
	defer mu.Unlock()

	if errorParam != "" {
		authCode.Error = errorParam
		authCode.Code = ""
		fmt.Printf("Authorization error: %s\n", errorParam)
	} else if code != "" {
		authCode.Code = code
		authCode.Error = ""
		authCode.State = state
		fmt.Printf("Authorization code received: %s...\n", code[:20])
	}

	w.Header().Set("Content-Type", "text/html")
	if authCode.Error != "" {
		fmt.Fprintf(w, `<html><head><title>Spotify Authorization - Error</title></head>
<body style="font-family: Arial; text-align: center; padding: 40px;">
<h1>Authorization Failed</h1>
<p style="color: red; font-size: 18px;">%s</p>
<p>You can close this window and check the game console for details.</p>
</body></html>`, authCode.Error)
	} else if code != "" {
		fmt.Fprint(w, `<html><head><title>Spotify Authorization - Success</title></head>
<body style="font-family: Arial; text-align: center; padding: 40px;">
<h1>Authorization Successful!</h1>
<p style="font-size: 16px; color: green;">Authorization code has been captured</p>
<p>You can now return to Assetto Corsa</p>
<p style="font-size: 12px; color: gray;">This window can be closed.</p>
</body></html>`)
	}
}

func handleToken(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	defer mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(authCode)
}

func handleStatus(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	hasCode := authCode.Code != ""
	hasError := authCode.Error != ""
	mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":    "running",
		"has_code":  hasCode,
		"has_error": hasError,
		"timestamp": time.Now().Unix(),
	})
}

func handleExit(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprint(w, `{"status":"cleared"}`)
	os.Exit(0)
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	mu.Lock()
	hasCode := authCode.Code != ""
	mu.Unlock()

	codeStatus := "No"
	if hasCode {
		codeStatus = "Yes"
	}

	w.Header().Set("Content-Type", "text/html")
	fmt.Fprintf(w, `<html><head><title>Spotify Auth Server</title></head>
<body style="font-family: Arial; padding: 40px;">
<h1>Spotify OAuth Callback Server</h1>
<p><strong>Status:</strong> Running ✓</p>
<p><strong>Authorization Code Captured:</strong> %s</p>
<hr>
<h2>Endpoints:</h2>
<ul>
<li><code>GET /status</code> - Check server status (JSON)</li>
<li><code>GET /token</code> - Get captured authorization code (JSON)</li>
<li><code>GET /callback?code=...</code> - OAuth callback endpoint</li>
</ul>
</body></html>`, codeStatus)
}

func main() {
	http.HandleFunc("/", handleIndex)
	http.HandleFunc("/callback", handleCallback)
	http.HandleFunc("/token", handleToken)
	http.HandleFunc("/status", handleStatus)
	http.HandleFunc("/exit", handleExit)

	addr := fmt.Sprintf("127.0.0.1:%s", *port)
	fmt.Printf("Starting Spotify OAuth Callback Server...\n")
	fmt.Printf("Listening on http://%s\n", addr)
	fmt.Printf("Press Ctrl+C to stop\n")

	if err := http.ListenAndServe(addr, nil); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
