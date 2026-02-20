# Makefile integration for VNDK compatibility generation

ifeq ($(TARGET_ENABLE_VNDK_COMPAT),true)

VNDK_COMPAT_VERSIONS := $(TARGET_VNDK_COMPAT_VERSIONS)
VNDK_COMPAT_TOOLS := build/make/tools/vndk_compat/

# Define the analysis step
VNDK_COMPAT_ANALYSIS_JSON := $(PRODUCT_OUT)/vndk_compat_analysis.json
$(VNDK_COMPAT_ANALYSIS_JSON): $(VNDK_COMPAT_TOOLS)/analyze_dependencies.py
	@echo "Analyzing vendor dependencies for VNDK compatibility..."
	$(hide) python3 $< --vendor $(TARGET_VENDOR_PATH) \
		--system-libs $(PRODUCT_OUT)/system_libs.txt \
		--output $@

# Define the linker config generation
VNDK_COMPAT_LINKER_CONFIG := $(PRODUCT_OUT)/system/etc/linker.config.json
$(VNDK_COMPAT_LINKER_CONFIG): $(VNDK_COMPAT_TOOLS)/generate_linker_config.py
	@echo "Generating VNDK compatibility linker configuration..."
	$(hide) python3 $< --versions $(subst $(space),$(comma),$(VNDK_COMPAT_VERSIONS)) \
		--output $@

# Add to the system image dependencies
INTERNAL_SYSTEMIMAGE_FILES += $(VNDK_COMPAT_ANALYSIS_JSON) $(VNDK_COMPAT_LINKER_CONFIG)

endif
