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
	System_scan_dir  *string
	Vendor_scan_dir  *string
}

type VndkCompatEngine struct {
	android.ModuleBase
	properties VndkCompatEngineProperties
}

func (m *VndkCompatEngine) GenerateAndroidBuildActions(ctx android.ModuleContext) {
	systemModel := android.PathForModuleOut(ctx, "system.model.json")
	vendorFootprint := android.PathForModuleOut(ctx, "vendor.footprint.json")
	compatPlan := android.PathForModuleOut(ctx, "compat_plan.json")
	scoreProps := android.PathForModuleOut(ctx, "vndk_compat.prop")

	// 1. Generate System Model
	ctx.Build(pctx, android.BuildParams{
		Rule:        modelGenRule,
		Description: "VNDK API Model Generation",
		Output:      systemModel,
		Args: map[string]string{
			"api_level": android.StringValue(m.properties.System_api_level),
			"scan_dir":  *m.properties.System_scan_dir,
		},
	})

	// 2. Generate Vendor Footprint
	ctx.Build(pctx, android.BuildParams{
		Rule:        modelGenRule,
		Description: "Vendor Footprint Extraction",
		Output:      vendorFootprint,
		Args: map[string]string{
			"api_level": android.StringValue(m.properties.Vendor_api_level),
			"scan_dir":  *m.properties.Vendor_scan_dir,
		},
	})

	// 3. Diff Engine
	policyPath := android.PathForSource(ctx, *m.properties.Policy_dir, "v"+android.StringValue(m.properties.Vendor_api_level)+".policy.json")
	ctx.Build(pctx, android.BuildParams{
		Rule:        diffEngineRule,
		Description: "VNDK Compatibility Scrutiny",
		Output:      compatPlan,
		Inputs:      android.Paths{systemModel, vendorFootprint, policyPath},
		Args: map[string]string{
			"sys_model":   systemModel.String(),
			"v_footprint": vendorFootprint.String(),
			"policy":      policyPath.String(),
		},
	})

	// 4. Scoring System
	ctx.Build(pctx, android.BuildParams{
		Rule:        scoringRule,
		Description: "VNDK Compatibility Scoring",
		Output:      scoreProps,
		Input:       compatPlan,
	})
}

func VndkCompatEngineFactory() android.Module {
	module := &VndkCompatEngine{}
	module.AddProperties(&module.properties)
	android.InitAndroidModule(module)
	return module
}

var (
	pctx = android.NewPackageContext("android/soong/vndk/compat")

	modelGenRule = pctx.AndroidStaticRule("modelGenRule",
		blueprint.RuleParams{
			Command:     "python3 build/make/tools/vndk_compat/vndk_api_model.py --api-level $api_level --scan-dir $scan_dir --output $out",
			CommandDeps: []string{"build/make/tools/vndk_compat/vndk_api_model.py"},
		},
		"api_level", "scan_dir")

	diffEngineRule = pctx.AndroidStaticRule("diffEngineRule",
		blueprint.RuleParams{
			Command:     "python3 build/make/tools/vndk_compat/vndk_diff_engine.py --system-model $sys_model --vendor-footprint $v_footprint --policy $policy --output $out",
			CommandDeps: []string{"build/make/tools/vndk_compat/vndk_diff_engine.py"},
		},
		"sys_model", "v_footprint", "policy")

	scoringRule = pctx.AndroidStaticRule("scoringRule",
		blueprint.RuleParams{
			Command:     "python3 build/make/tools/vndk_compat/scoring_system.py --plan $in --output-props $out",
			CommandDeps: []string{"build/make/tools/vndk_compat/scoring_system.py"},
		})
)
