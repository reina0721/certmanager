package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/rin721/certmate/internal/setuphelper"
)

func TestServerSetupHelperCommands(t *testing.T) {
	var output bytes.Buffer
	if err := setuphelper.Run([]string{"random-secret"}, strings.NewReader(""), &output); err != nil {
		t.Fatalf("setuphelper random-secret 失败: %v", err)
	}
	secret := strings.TrimSpace(output.String())
	if len(secret) != 64 {
		t.Fatalf("预期 64 位十六进制字符串，得到: %s", secret)
	}
}
