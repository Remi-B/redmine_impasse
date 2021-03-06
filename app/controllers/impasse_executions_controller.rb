require 'erb'

class ImpasseExecutionsController < ImpasseAbstractController
  unloadable

  REL = {1=>"test_project", 2=>"test_suite", 3=>"test_case"}

  menu_item :impasse
  before_filter :find_project_by_project_id, :authorize

  include ActionView::Helpers::AssetTagHelper

  def index
    params[:tab] = 'execution'
    @test_plan = Impasse::TestPlan.find(params[:id])
  end

  def put
    @node = Impasse::Node.find(params[:test_plan_case][:test_case_id])
    test_case_ids = (@node.is_test_case?) ? [ @node.id ] : @node.all_decendant_cases.collect{|tc| tc.id}
    if params[:execution] and params[:execution][:expected_date]
      params[:execution][:expected_date] = Time.at(params[:execution][:expected_date].to_i)
    end

    status = 'success'
    for test_case_id in test_case_ids
      begin
        @test_plan_case = Impasse::TestPlanCase.find(:first, :conditions=>[
                                                                "test_plan_id=? AND test_case_id=?",
                                                                params[:test_plan_case][:test_plan_id],
                                                                test_case_id])
        next if @test_plan_case.nil?
        @execution = Impasse::Execution.find_or_initialize_by_test_plan_case_id(@test_plan_case.id)
        @execution.attributes = params[:execution]
        @execution.execution_ts = Time.now.to_datetime
        unless @execution.save
          status = 'error'
        end
      rescue
        status = 'error'
      end
    end
    
    respond_to do |format|
      format.json { render :json => { :status => status, :message => status ? l(:notice_successful_update) : l(:error_unable_to_connect) } }
    end
  end

  def destroy
    node = Impasse::Node.find(params[:test_plan_case][:test_case_id])
    test_case_ids = (node.is_test_case?) ? [ node.id ] : node.all_decendant_cases.collect{|tc| tc.id}

    status = true
    for test_case_id in test_case_ids
      test_plan_case = Impasse::TestPlanCase.find(:first, :conditions=>[
                         "test_plan_id=? AND test_case_id=?", params[:test_plan_case][:test_plan_id], test_case_id])
      next if test_plan_case.nil?
      execution = Impasse::Execution.find_by_test_plan_case_id(test_plan_case.id)
      next if execution.nil?
      execution.tester_id = execution.expected_date = nil
      satus &= execution.save
    end

    respond_to do |format|
      format.json { render :json => { :status => status } }
    end
  end

  def get_list
    sql = <<-'END_OF_SQL'
SELECT T.*, users.firstname, users.lastname, exec.expected_date, exec.status
FROM (
  SELECT distinct parent.*, tpc.test_plan_id
  FROM impasse_nodes AS parent
  LEFT JOIN impasse_nodes AS child
    ON INSTR(child.path, parent.path) > 0
  LEFT JOIN impasse_test_cases AS tc
    ON child.id = tc.id
  LEFT JOIN impasse_test_plan_cases AS tpc
    ON tc.id=tpc.test_case_id
  WHERE tpc.test_plan_id=:test_plan_id
<%- if conditions.include? :path -%>
    AND parent.path LIKE :path
<%- end -%>
) AS T
LEFT JOIN impasse_test_plan_cases AS tpcs
  ON T.id=tpcs.test_case_id AND T.test_plan_id = tpcs.test_plan_id
LEFT JOIN impasse_executions AS exec
  ON tpcs.id = exec.test_plan_case_id
LEFT OUTER JOIN users
  ON users.id = exec.tester_id
<%- if [:user_id, :execution_status, :expected_date].any? {|key| conditions.include? key} -%>
WHERE T.node_type_id != '3' OR (1=1
  <%- if conditions.include? :user_id -%>
  AND tester_id = :user_id
  <%- end -%>
  <%- if conditions.include? :execution_status -%>
  AND (exec.status IN (:execution_status) <%- if conditions[:execution_status].include? "0" %>OR exec.status IS NULL<% end %> )
  <% end %>
  <%- if conditions.include? :expected_date -%>
  AND exec.expected_date <%= conditions[:expected_date_op] %> :expected_date
  <%- end -%>)
<%- end -%>
ORDER BY LENGTH(T.path) - LENGTH(REPLACE(T.path,'.','')), T.node_order
END_OF_SQL

    conditions = { :test_plan_id => params[:test_plan_id] }

    if params.include? :id and params[:id] != "-1" # TODO
      node = Impasse::Node.find(params[:id])
      conditions[:path] = "#{node.path}_%"
    end

    if params[:myself]
      conditions[:user_id] = User.current.id
    end

    if params.include? :execution_status
      conditions[:execution_status] = []
      if params[:execution_status].is_a? Array
        params[:execution_status].each {|param|
          conditions[:execution_status] << param.to_s
        }
      else
        conditiions[:execution_status] << params[:execution_status].to_s
      end
    end

    if params.include? :expected_date
      conditions[:expected_date] = params[:expected_date]
      conditions[:expected_date_op] = params[:expected_date_op] || '='
    end
    @nodes = Impasse::Node.find_by_sql([ERB.new(sql, nil, '-').result(binding), conditions])

    jstree_nodes = convert(@nodes, params[:prefix])

    respond_to do |format|
      format.json { render :json => jstree_nodes }
    end
  end

  def edit
    sql = <<-END_OF_SQL
SELECT impasse_executions.*
FROM impasse_executions
WHERE exists (
  SELECT *
  FROM impasse_test_plan_cases AS tpc
  WHERE impasse_executions.test_plan_case_id = tpc.id
    AND tpc.test_plan_id=? AND tpc.test_case_id=?)
END_OF_SQL
    executions = Impasse::Execution.find_by_sql [sql, params[:test_plan_case][:test_plan_id], params[:test_plan_case][:test_case_id]]
    if executions.size == 0
      @execution = Impasse::Execution.new
      @execution.test_plan_case = Impasse::TestPlanCase.find_by_test_plan_id_and_test_case_id(
        params[:test_plan_case][:test_plan_id], params[:test_plan_case][:test_case_id])
    else
      @execution = executions.first
    end
    @execution.attributes = params[:execution]
    if request.post? and @execution.save
      respond_to do |format|
        format.json { render :json => {'status'=>true} }
      end
    end
    respond_to do |format|
      format.html { render :partial=>'edit' }
    end
  end

  def convert(nodes, prefix='node')
    node_map = {}
    jstree_nodes = []
    
    for node in nodes
      jstree_node = {
        'attr' => {'id' => "#{prefix}_#{node.id}" , 'rel' => REL[node.node_type_id]},
        'data' => {},
        'children'=>[]}
      jstree_node['data']['title'] = node.name
      if node.node_type_id != 3
        jstree_node['state'] = 'open'
      end
      assign_text = []
      if node.firstname or node.lastname
        firstname = node.firstname
        lastname  = node.lastname
        assign_text << eval('"' + User.name_formatter[:string] + '"')
      end
      if node.expected_date
        assign_text << format_date(node.expected_date)
      end
      if assign_text.size > 0
        jstree_node['data']['title'] << " (#{assign_text.join(' ')})"
      end

      jstree_node['data']['icon'] = status_icon(node.status) if node.node_type_id == 3

      node_map[node.id] = jstree_node
      if node_map.include? node.parent_id
        # non-root node
        node_map[node.parent_id]['children'] << jstree_node
      else
        #root node
        jstree_nodes << jstree_node
      end
    end
    jstree_nodes
  end

  def status_icon(status)
    icon_dir = Redmine::Utils::relative_url_root + "/plugin_assets/redmine_impasse/stylesheets/images"
    [
     "#{icon_dir}/document-attribute-t.png",
     "#{icon_dir}/tick.png",
     "#{icon_dir}/cross.png",
     "#{icon_dir}/wall-brick.png",
    ][status.to_i]
  end
end
