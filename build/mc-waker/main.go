// Package main is the entry point for mc-waker, a tiny TCP proxy + Minecraft
// Server List Ping (SLP) responder used to drive scale-from-zero on OpenShift
// via the Custom Metrics Autoscaler (KEDA).
//
// Behavior in one paragraph: mc-waker always listens on TCP port 25565 for
// Java clients. When a client connects, the waker checks the real Minecraft
// server. If the server is up, the connection is bidirectionally proxied.
// If the server is down (because it has been scaled to zero), the waker
// answers locally with a "Server is sleeping" MOTD and raises a wake signal
// that the ScaledObject scrapes to bring the server back to one replica.
package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	cfg := parseFlags()

	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel}))
	slog.SetDefault(log)

	st := newState(cfg, log)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	go runProbe(ctx, st)
	go runHTTP(ctx, st)

	runProxy(ctx, st) // blocking
}
