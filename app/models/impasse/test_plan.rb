module Impasse
  class TestPlan < ActiveRecord::Base
    unloadable
    set_table_name "impasse_test_plans"
    self.include_root_in_json = false

    has_many :test_plan_cases
    has_many :test_cases, :through => :test_plan_cases
    belongs_to :version

    validates_presence_of :name
    validates_length_of :name, :maximum => 100

    def self.find_all_by_version(project, show_closed = false)
      versions = project.shared_versions || []
      versions = versions.uniq.sort
      unless show_closed
        versions.reject! {|version| version.closed? || version.completed? }
      end

      test_plans_by_version = {}
      versions.each do |version|
        test_plans = TestPlan.find(:all, :conditions => ["version_id=?", version.id])
        test_plans_by_version[version] = test_plans
      end
      [test_plans_by_version, versions]
    end
  end
end
