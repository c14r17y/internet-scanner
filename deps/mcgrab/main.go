package main  
  
import (  
	"bufio"  
	"context"  
	"encoding/json"  
	"flag"  
	"fmt"  
	"net"  
	"os"  
	"strconv"  
	"strings"  
	"sync"  
	"time"  
  
	"github.com/mcstatus-io/mcutil/v4/status"  
)  
  
type SamplePlayerInfo struct {  
	ID   string `json:"id"`  
	Name string `json:"name"`  
}  
  
type ModEntry struct {  
	ID      string `json:"id"`  
	Version string `json:"version"`  
}  
  
type ModsInfo struct {  
	Type string     `json:"type"`  
	List []ModEntry `json:"list"`  
}  
  
type ServerInfo struct {  
	IP            string             `json:"ip"`  
	Port          uint16             `json:"port"`  
	MOTD          string             `json:"motd"`  
	PingMS        int64              `json:"ping ms,omitempty"`  
	Version       string             `json:"version"`  
	Protocol      int64              `json:"protocol"`  
	MaxPlayers    int64              `json:"max players"`  
	CurrentOnline int64              `json:"current online"`  
	Players       []SamplePlayerInfo `json:"players,omitempty"`  
	Favicon       *string            `json:"favicon,omitempty"`  
	Mods          *ModsInfo          `json:"mods,omitempty"`  
	Edition       *string            `json:"edition,omitempty"`  
	Gamemode      *string            `json:"gamemode,omitempty"`  
}  
  
type Result struct {  
	Target string      `json:"target"`  
	Result *ServerInfo `json:"result,omitempty"`  
	Error  string      `json:"error,omitempty"`  
}  
  
var javaPorts = map[uint16]bool{25565: true, 25566: true, 25567: true}  
var bedrockPorts = map[uint16]bool{19132: true, 19133: true}  
  
type portType int  
  
const (  
	ptJava    portType = iota  
	ptBedrock portType = iota  
	ptUnknown portType = iota  
)  
  
func detectPort(port uint16) portType {  
	if javaPorts[port] {  
		return ptJava  
	}  
	if bedrockPorts[port] {  
		return ptBedrock  
	}  
	return ptUnknown  
}  
  
func fillFromModern(info *ServerInfo, host string, port uint16, ctx context.Context) error {  
	resp, err := status.Modern(ctx, host, port)  
	if err != nil {  
		return err  
	}  
	info.Version = resp.Version.Name.Clean  
	info.MOTD = resp.MOTD.Clean  
	info.PingMS = resp.Latency.Milliseconds()  
	info.Protocol = resp.Version.Protocol  
	info.Favicon = resp.Favicon  
	if resp.Players.Online != nil {  
		info.CurrentOnline = *resp.Players.Online  
	}  
	if resp.Players.Max != nil {  
		info.MaxPlayers = *resp.Players.Max  
	}  
	for _, p := range resp.Players.Sample {  
		info.Players = append(info.Players, SamplePlayerInfo{  
			ID:   p.ID,  
			Name: p.Name.Clean,  
		})  
	}  
	if resp.Mods != nil {  
		mods := &ModsInfo{Type: resp.Mods.Type}  
		for _, m := range resp.Mods.List {  
			mods.List = append(mods.List, ModEntry{ID: m.ID, Version: m.Version})  
		}  
		info.Mods = mods  
	}  
	return nil  
}  
  
func fillFromLegacy(info *ServerInfo, host string, port uint16, ctx context.Context) error {  
	resp, err := status.Legacy(ctx, host, port)  
	if err != nil {  
		return err  
	}  
	if resp.Version != nil {  
		info.Version = resp.Version.Name.Clean  
		info.Protocol = resp.Version.Protocol  
	}  
	info.MOTD = resp.MOTD.Clean  
	info.CurrentOnline = resp.Players.Online  
	info.MaxPlayers = resp.Players.Max  
	return nil  
}  
  
func fillFromBedrock(info *ServerInfo, host string, port uint16, ctx context.Context) error {  
	resp, err := status.Bedrock(ctx, host, port)  
	if err != nil {  
		return err  
	}  
	if resp.MOTD != nil {  
		info.MOTD = resp.MOTD.Clean  
	}  
	if resp.Version != nil {  
		info.Version = *resp.Version  
	}  
	if resp.ProtocolVersion != nil {  
		info.Protocol = *resp.ProtocolVersion  
	}  
	if resp.OnlinePlayers != nil {  
		info.CurrentOnline = *resp.OnlinePlayers  
	}  
	if resp.MaxPlayers != nil {  
		info.MaxPlayers = *resp.MaxPlayers  
	}  
	info.Edition = resp.Edition  
	info.Gamemode = resp.Gamemode  
	return nil  
}  
  
func fillJavaWithFallback(info *ServerInfo, host string, port uint16, ctx context.Context) error {  
	err := fillFromModern(info, host, port, ctx)  
	if err != nil && strings.Contains(err.Error(), "unexpected input type") {  
		return fillFromLegacy(info, host, port, ctx)  
	}  
	return err  
}  
  
type probeResult struct {  
	info *ServerInfo  
	err  error  
}  
  
func probeUnknown(host string, port uint16) (*ServerInfo, error) {  
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)  
	defer cancel()  
  
	ch := make(chan probeResult, 2)  
  
	go func() {  
		info := &ServerInfo{IP: host, Port: port}  
		err := fillJavaWithFallback(info, host, port, ctx)  
		ch <- probeResult{info, err}  
	}()  
  
	go func() {  
		info := &ServerInfo{IP: host, Port: port}  
		err := fillFromBedrock(info, host, port, ctx)  
		ch <- probeResult{info, err}  
	}()  
  
	var lastErr error  
	for i := 0; i < 2; i++ {  
		r := <-ch  
		if r.err == nil {  
			return r.info, nil  
		}  
		lastErr = r.err  
	}  
	return nil, fmt.Errorf("both java and bedrock failed: %v", lastErr)  
}  
  
func probe(host string, port uint16) Result {  
	target := fmt.Sprintf("%s:%d", host, port)  
	info := &ServerInfo{IP: host, Port: port}  
  
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)  
	defer cancel()  
  
	var err error  
	switch detectPort(port) {  
	case ptJava:  
		err = fillJavaWithFallback(info, host, port, ctx)  
	case ptBedrock:  
		err = fillFromBedrock(info, host, port, ctx)  
	case ptUnknown:  
		info, err = probeUnknown(host, port)  
	}  
  
	if err != nil {  
		return Result{Target: target, Error: err.Error()}  
	}  
	return Result{Target: target, Result: info}  
}  
  
func main() {  
	workers := flag.Int("workers", 200, "number of concurrent workers")  
	flag.Parse()  
  
	jobs := make(chan string, *workers*2)  
	results := make(chan Result, *workers*2)  
  
	var wg sync.WaitGroup  
	for i := 0; i < *workers; i++ {  
		wg.Add(1)  
		go func() {  
			defer wg.Done()  
			for addr := range jobs {  
				host, portStr, err := net.SplitHostPort(addr)  
				if err != nil {  
					results <- Result{Target: addr, Error: err.Error()}  
					continue  
				}  
				portU64, err := strconv.ParseUint(portStr, 10, 16)  
				if err != nil {  
					results <- Result{Target: addr, Error: err.Error()}  
					continue  
				}  
				results <- probe(host, uint16(portU64))  
			}  
		}()  
	}  
  
	go func() {  
		wg.Wait()  
		close(results)  
	}()  
  
	go func() {  
		scanner := bufio.NewScanner(os.Stdin)  
		for scanner.Scan() {  
			line := strings.TrimSpace(scanner.Text())  
			if line != "" {  
				jobs <- line  
			}  
		}  
		close(jobs)  
	}()  
  
	enc := json.NewEncoder(os.Stdout)  
	for r := range results {  
		enc.Encode(r)  
	}  
}