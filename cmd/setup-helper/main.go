// setup-helper 仅在 Docker 部署初始化阶段生成 bcrypt 哈希和随机 Secret。
package main

import (
	"fmt"
	"os"

	"github.com/rin721/certmate/internal/setuphelper"
)

func main() {
	if err := setuphelper.Run(os.Args[1:], os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "初始化工具错误:", err)
		os.Exit(1)
	}
}
