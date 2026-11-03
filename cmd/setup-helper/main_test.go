package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/rin721/certmate/internal/setuphelper"
)

func TestSetupHelperCommand(t *testing.T) {
	var output bytes.Buffer
	if err := setuphelper.Run([]string{"random-secret"}, strings.NewReader(""), &output); err != nil {
		t.Fatal(err)
	}
	if len(strings.TrimSpace(output.String())) != 64 {
		t.Fatalf("预期 64 字符十六进制 Secret，得到: %s", output.String())
	}
}
