class ImpasseSettingsController < ImpasseAbstractController
  unloadable

  before_filter :find_project_by_project_id, :authorize

  def index
  end

  def edit
    @setting = Impasse::Setting.find_or_create_by_project_id(:project_id => @project.id)
    @setting.attributes = params[:setting]
    @setting.save if request.put? or request.post?
    flash[:notice] = l(:notice_successful_update)
    redirect_to :controller => '/projects', :action => 'settings', :id => @project, :tab => 'impasse'
  end
end
