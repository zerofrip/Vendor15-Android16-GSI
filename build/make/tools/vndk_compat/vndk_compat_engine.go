package vndk

import (
	"android/soong/android"

	"github.com/google/blueprint"
)

func init() {
	android.RegisterModuleType("vndk_compat_engine", VndkCompatEngineFactory)
}

type VndkCompatEngineProperties struct {
	Vendor_api_level *int
	System_api_level *int
	Policy_dir       *string
}

type VndkCompatEngine struct {
	android.ModuleBase
	properties VndkCompatEngineProperties
}

func (m *VndkCompatEngine) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	planFile := android.PathForModuleOut(ctx, "compat_plan.json")
	vendorDir := android.PathForSource(ctx, "vendor") // Simplified for reference
	systemDir := android.PathForSource(ctx, "system") // Simplified for reference

	// 1. Run the Engine to generate the plan
	ctx.Build(pctx, android.BuildParams{
		Rule:        engineRule,
		Description: "VNDK Compat Engine Analysis",
		Output:      planFile,
		Args: map[string]string{
			"vendor_api": android.StringValue(m.properties.Vendor_api_level),
			"system_api": android.StringValue(m.properties.System_api_level),
			"policy_dir": *m.properties.Policy_dir,
			"vendor_dir": vendorDir.String(),
			"system_dir": systemDir.String(),
		},
	})

	// 2. Based on planFile, subsequent rules (not shown for brevity)
	// would trigger shim_generator.py and linker_config_ast.py
}

func VndkCompatEngineFactory() android.Module {
	module := &VndkCompatEngine{}
	module.AddProperties(&module.properties)
	android.InitAndroidModule(module)
	return module
}

var (
	pctx = android.NewPackageContext("android/soong/vndk/compat")

	engineRule = pctx.AndroidStaticRule("engineRule",
		blueprint.RuleParams{
			Command:     "python3 build/make/tools/vndk_compat/vndk_compat_engine.py --vendor-api $vendor_api --system-api $system_api --vendor-dir $vendor_dir --system-dir $system_dir --policy-dir $policy_dir --output $out",
			CommandDeps: []string{"build/make/tools/vndk_compat/vndk_compat_engine.py"},
		},
		"vendor_api", "system_api", "policy_dir", "vendor_dir", "system_dir")
)
