require 'spec_helper'
require 'mysigner/build/parser'
require 'mysigner/build/detector'

RSpec.describe Mysigner::Build::Parser do
  describe 'advanced project features' do
    describe '#app_targets' do
      it 'returns all application targets' do
        # This would need a real project with multiple apps
        # For now, we test that it returns an array
        skip 'Requires test project with multiple apps'
      end
    end

    describe '#extension_targets' do
      it 'returns all extension targets' do
        # This would need a project with extensions
        skip 'Requires test project with extensions'
      end
      
      it 'returns empty array when no extensions' do
        # For standard single-app project
        skip 'Requires test project'
      end
    end

    describe '#all_app_targets' do
      it 'returns main app plus extensions' do
        skip 'Requires test project with extensions'
      end
    end

    describe '#has_extensions?' do
      it 'returns true when project has extensions' do
        skip 'Requires test project with extensions'
      end
      
      it 'returns false when project has no extensions' do
        skip 'Requires test project'
      end
    end

    describe '#has_multiple_apps?' do
      it 'returns true when project has multiple apps' do
        skip 'Requires test project with multiple apps'
      end
      
      it 'returns false for single app project' do
        skip 'Requires test project'
      end
    end

    describe '#target_platform' do
      it 'detects iOS platform' do
        skip 'Requires test project'
      end
      
      it 'detects macOS platform' do
        skip 'Requires macOS test project'
      end
      
      it 'detects tvOS platform' do
        skip 'Requires tvOS test project'
      end
      
      it 'detects watchOS platform' do
        skip 'Requires watchOS test project'
      end
    end

    describe '#product_type' do
      it 'detects app product type' do
        skip 'Requires test project'
      end
      
      it 'detects framework product type' do
        skip 'Requires framework test project'
      end
      
      it 'detects library product type' do
        skip 'Requires library test project'
      end
      
      it 'detects extension product type' do
        skip 'Requires extension test project'
      end
    end
  end

  describe 'backward compatibility' do
    it 'main_target still works as before' do
      skip 'Requires test project - verify existing behavior unchanged'
    end
    
    it 'bundle_id still works as before' do
      skip 'Requires test project - verify existing behavior unchanged'
    end
    
    it 'code_sign_style still works as before' do
      skip 'Requires test project - verify existing behavior unchanged'
    end
  end
end
